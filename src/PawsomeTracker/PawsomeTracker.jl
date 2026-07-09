module PawsomeTracker

using ImageFiltering: Kernel, imfilter!, Algorithm, NoPad
using OffsetArrays: OffsetMatrix
using PaddedViews: PaddedView
using FFMPEG: exe, ffprobe
using VideoIO: openvideo, AV_PIX_FMT_GRAY8, aspect_ratio, open_video_out, VideoWriter, VideoReader, close_video_out!, framerate, skipframes, gettime, get_duration
using ImageDraw: draw!, CirclePointRadius, Path
using FreeTypeAbstraction: renderstring!, FTFont
using ColorTypes: Gray
using FixedPointNumbers: N0f8
using ImageTransformations: imresize!, warp, WarpedView
using RelocatableFolders: @path
using ComputationalResources: CPUThreads
using DataStructures: CircularBuffer
using StaticArrays: SVector, SDiagonal
using OpenCV: OpenCV
using CoordinateTransformations: LinearMap
using LinearAlgebra: I

const DEFAULT_MAX_DURATION_SECONDS = 86399.999  # 24 hours minus 1 millisecond
const RowCol = SVector{2, Float32}

# Confidence gate for `detect`: when the window's peak DoG response falls below GATE_FRACTION of
# the running response level, the frame is treated as "target not seen" (occlusion, glare,
# washout) and the tracker holds its last position instead of chasing the weighted mean of noise.
# The level is an exponential moving average of accepted peaks — self-normalized, so there is no
# per-video threshold to tune — and it decays slowly while holding, so a genuine, lasting drop in
# contrast eventually re-opens the gate.
const GATE_FRACTION = 0.2
const LEVEL_SMOOTH = 0.9
const GATE_DECAY = 0.99

export track

include("diagnose.jl")

function get_framerate(file)
    vid_fps = openvideo(framerate, file)
    !isinf(vid_fps) && return vid_fps
    txt = exe(` -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 $file`, command=ffprobe, collect=true)
    parse(Rational{Int}, only(txt))
end

get_sigma(target_width) = target_width / 2sqrt(2log(2))

function get_window(target_width, fps, m, t)
    σ = get_sigma(target_width)
    ws1 = 4ceil(Int, σ) + 1 # calculates the default window size

    speed = m/t # pixels per second
    distance = speed / fps # distance traveled per frame
    ws2 = round(Int, 2distance)

    max(ws1, ws2)
end

function fix_window_size(wh::NTuple{2, Int}) 
    w, h = wh
    if !isodd(w)
        w += 1
    end
    if !isodd(h)
        h += 1
    end
    return (h, w)
end

function fix_window_size(l::Int) 
    if !isodd(l)
        l += 1
    end
    return (l, l)
end

function get_guess(start_index::RowCol, _, vid, _, _, _)
    guess = round.(Int, Tuple(vid.scale * start_index))
    return guess
end

function get_guess(start_xy::NTuple{2, Int}, _, vid, _, _, _)
    x, y = start_xy
    guess = round.(Int, vid.scale .* (y, x / vid.sar))
    return guess
end

# todo: when the scale is lower then the tracker fails

function get_guess(::Missing, stack, vid, darker_target, target_width, initial_search_factor)
    sz = size(parent(stack))[1:2]
    guess = sz .÷ 2
    window_size = fix_window_size(floor(Int, min(sz...) / initial_search_factor))
    tr = Tracker(vid, darker_target, target_width, window_size)
    _, guess = detect(guess, stack, 1, tr.h, tr.img, tr.radii, tr.buff, tr.kernel, tr.sz, vid.scale, tr.bkgd_reduce)
    return guess
end

struct Video
    vid::VideoReader
    img::PermutedDimsArray{Gray{N0f8}, 2, (2, 1), (2, 1), Matrix{Gray{N0f8}}}
    skip::Int
    nframes::Int
    scale::Float64
    width::Int
    height::Int
    duration::Float64
    fps::Float64
    sar::Rational

    function Video(file, fps, start, stop, scale)
        vid = openvideo(file; target_format = AV_PIX_FMT_GRAY8)
        vid_fps = framerate(vid)
        fps = min(fps, vid_fps)
        skip = round(Int, vid_fps / fps)
        img = read(vid)
        t₀ = gettime(vid)
        height, width = size(img)
        tform = LinearMap(1/scale)
        height, width = size(WarpedView(Array{Gray{Float32}}(undef, size(img)...), tform; fillvalue = zero(Gray{Float32})))
        seek(vid, start + t₀)
        nframes = round.(Int, fps*(stop - start))
        sar = aspect_ratio(vid)
        new(vid, img, skip, nframes, scale, width, height, stop - start, fps, sar)
    end
end

function video(f, file, fps, start, stop, scale)
    vid = Video(file, fps, start, stop, scale)
    return try
        f(vid)
    finally
        close(vid.vid)
    end
end

function next!(v::Video)
    read!(v.vid, v.img)
    if !isone(v.skip)
        skipframes(v.vid, v.skip - 1, throwEOF = false)
    end
end


struct Tracker
    img::PaddedView{Gray{Float32}, 2, Tuple{Base.IdentityUnitRange{UnitRange{Int64}}, Base.IdentityUnitRange{UnitRange{Int64}}}, Matrix{Gray{Float32}}}
    buff::OffsetMatrix{Float64, Matrix{Float64}}
    kernel::OffsetMatrix{Float64, Matrix{Float64}}
    h::NTuple{2, Int}
    radii::Tuple{Int64, Int64}
    sz::Tuple{Int64, Int64}
    # the temporal reduction that models the background: a darker target never raises the
    # per-pixel maximum over time, so `maximum` sees through it — a lighter target instead
    # *is* the maximum wherever it ever passed (erasing itself and leaving a ghost swath along
    # its own trajectory), so there the background is the per-pixel `minimum`.
    bkgd_reduce::Union{typeof(maximum), typeof(minimum)}
    function Tracker(vid, darker_target, target_width, window_size)
        # window_size arrives as (rows, cols) in display pixels; the stored frame is squeezed
        # horizontally by sar (stored x = display x / sar), so the column extent is converted to
        # stored pixels — otherwise an anamorphic (sar < 1) target fills its own search window.
        radii = (window_size[1], round(Int, window_size[2] / vid.sar)) .÷ 2
        σ = get_sigma(target_width)
        direction = darker_target ? -1 : +1
        fillvalue = zero(Gray{Float32})
        kernel = direction * Kernel.DoG((σ/vid.sar, σ))
        h = radii .+ size(kernel)

        sz = (vid.height, vid.width)
        pad_indices = UnitRange.(1 .- h, sz .+ h)
        img = PaddedView(fillvalue, Matrix{Gray{Float32}}(undef, vid.height, vid.width), pad_indices)
        _buff = Matrix{Float64}(undef, length.(pad_indices))
        buff = OffsetMatrix(_buff, pad_indices)
        new(img, buff, kernel, h, radii, sz, darker_target ? maximum : minimum)
    end
end

function build_stack(scale, sz, n_bkgd, pad_indices)
    tform = LinearMap(SDiagonal(SVector{3, Float64}(1/scale, 1/scale, 1)))
    PaddedView(zero(Gray{Float32}), WarpedView(Array{Gray{Float32}}(undef, sz..., n_bkgd), tform; fillvalue = zero(Gray{Float32})), pad_indices)
end

function get_stack(vid, sz, h)
    n_bkgd = vid.nframes > 250 ? 250 : vid.nframes
    pad_indices = UnitRange.(((1 .- h)..., 1), ((sz .+ h)..., n_bkgd))
    build_stack(vid.scale, size(vid.img), n_bkgd, pad_indices)
end

populate_slice!(stack, i, vid) = copy!(selectdim(parent(parent(stack)), 3, i), vid.img)

# Keep the (possibly long-stationary) target OUT of the background history. The stack doubles as
# the background model and as detect's source of the current frame, so the protection happens
# AFTER detection: the frame enters the stack whole (detect must see the target), and once the
# position is known the target's search window (the same guess ± radii rectangle detect scans) in
# that slice is restored to the pre-target background the evicted frame held there. By induction
# the history never contains the target — a target that sits still for longer than the rolling
# window would otherwise be absorbed by the per-pixel max/min, erased from the subtracted image,
# and the tracker set wandering. (The prefill in collect_stack is unprotected: absorption needs
# the stationary spell to exceed the whole background window within the rolling phase.)
function protect_target(stack, j, guess, radii, scale)
    slice = selectdim(parent(parent(stack)), 3, j)
    protect = CartesianIndices(UnitRange.(round.(Int, (guess .- radii) ./ scale),
                                          round.(Int, (guess .+ radii) ./ scale))) ∩ CartesianIndices(slice)
    return protect, slice[protect]
end

function restore_background!(stack, j, protect, keep)
    selectdim(parent(parent(stack)), 3, j)[protect] = keep
    return
end

# Sequential on purpose: next!(vid) decodes into the single shared vid.img buffer, so copying
# slice i must complete before the next read — a spawned copy raced the following next! and
# nondeterministically corrupted background slices with (parts of) the wrong frame.
function collect_stack(vid, sz, h)
    stack = get_stack(vid, sz, h)
    for i in axes(stack, 3)
        next!(vid)
        populate_slice!(stack, i, vid)
    end
    return stack
end

_weightedmean(v) = mapreduce(+, zip(Iterators.product(parentindices(v)...), v)) do (rc, v)
    RowCol(rc) * v
end / sum(v)

function detect(guess, stack, j, h, img, radii, buff, kernel, sz, scale, bkgd_reduce = maximum, level = Ref(0.0))
    slice = selectdim(stack, 3, j)
    bkgd_indices = CartesianIndices(UnitRange.(guess .- h, guess .+ h)) ∩ CartesianIndices(Base.OneTo.(sz))
    img.data[bkgd_indices] .= slice[bkgd_indices] .- bkgd_reduce(stack[bkgd_indices, :], dims = 3)
    window_indices = UnitRange.(guess .- radii, guess .+ radii)
    imfilter!(CPUThreads(Algorithm.FIR()), buff, img, kernel, NoPad(), window_indices)
    v = view(buff, window_indices...)
    clamp!(v, 0, Inf)
    # the confidence gate (see GATE_FRACTION above): hold the last position when the response
    # collapses to noise, rather than wander after the weighted mean of nothing
    peak = maximum(v)
    if peak < GATE_FRACTION * level[]
        level[] *= GATE_DECAY
        return RowCol(guess) / scale, guess
    end
    level[] = level[] == 0 ? peak : LEVEL_SMOOTH * level[] + (1 - LEVEL_SMOOTH) * peak
    coord = _weightedmean(v)
    if any(isnan, coord)
        return RowCol(guess) / scale, guess
    end
    # coord = min.(max.(coord, (1, 1)), sz)
    guess = Tuple(round.(Int, coord))
    # return scaleit(coord, scale), guess
    return coord / scale, guess
end

function track!(coords, stack, guess, tr, vid, dia)
    level = Ref(0.0)                 # running response level for detect's confidence gate
    for i in axes(stack, 3)
        coords[i], guess = detect(guess, stack, i, tr.h, tr.img, tr.radii, tr.buff, tr.kernel, tr.sz, vid.scale, tr.bkgd_reduce, level)
        dia(selectdim(parent(parent(stack)), 3, i), round.(Int, Tuple(coords[i])))
    end
    n_bkgd = size(stack, 3)
    for i in n_bkgd + 1:vid.nframes
        next!(vid)
        j = mod1(i, n_bkgd)
        protect, keep = protect_target(stack, j, guess, tr.radii, vid.scale)
        populate_slice!(stack, j, vid)
        coords[i], guess = detect(guess, stack, j, tr.h, tr.img, tr.radii, tr.buff, tr.kernel, tr.sz, vid.scale, tr.bkgd_reduce, level)
        dia(selectdim(parent(parent(stack)), 3, j), round.(Int, Tuple(coords[i])))
        restore_background!(stack, j, protect, keep)
    end
end

function track_one(file, start, stop, target_width, start_location, window_size, darker_target, fps, dia, apriltags, initial_search_factor, white_point, scale)
    video(file, fps, start, stop, scale) do vid
        update_ratio!(dia, size(vid.img))
        tr = Tracker(vid, darker_target, target_width, window_size)
        stack = collect_stack(vid, tr.sz, tr.h)
        coords = Vector{RowCol}(undef, vid.nframes)
        guess = get_guess(start_location, stack, vid, darker_target, target_width, initial_search_factor)
        track!(coords, stack, guess, tr, vid, dia)
        return (range(start, stop, vid.nframes), coords)
    end
end

"""
    track(file::AbstractString; start, stop, target_width, start_location, window_size,
          darker_target, fps, diagnostic_file, rectification, scale, …)

Use a Difference of Gaussian (DoG) filter to track a target in the video `file` between `start`
and `stop` seconds, sampling `fps` frames per second (capped at the video's own rate). Returns
`(ts, coords)`: timestamps and the target's per-frame (row, col) coordinates in original-frame
pixels (`scale` only speeds tracking up; coordinates are always reported unscaled).
`start_location` is the target's `"(x, y)"` display-pixel position at `start`; when `missing` the
target is searched for around the frame center. When `diagnostic_file` (an `.mp4` path — that
container selects the H.264 encoder) is given, an annotated diagnostic video is written there,
playing at $(DIAGNOSTIC_SPEEDUP)× real time; pass a `rectification` to render it top-down through
that rectification instead of as the raw frame.
"""
function track(
        file::AbstractString;
        start::Real = 0,
        stop::Real = get_duration(file),
        target_width::Real = 25,
        start_location::Union{Missing, NTuple{2, Int}, CartesianIndex{2}} = missing,
        window_size::Union{Missing, Int, NTuple{2, Int}} = round(Int, 2target_width),
        darker_target::Bool = true,
        fps::Real = get_framerate(file),
        diagnostic_file::Union{Nothing, AbstractString} = nothing,
        apriltags::Int = 0,
        initial_search_factor::Real=4,
        scale::Real = 1,
        white_point::Real = 1,
        rectification = nothing # rectification object
    )

    diagnose(diagnostic_file, darker_target, rectification, fps) do dia
        track_one(file, start, stop, scale*target_width, start_location, round.(Int, scale .* fix_window_size(window_size)), darker_target, fps, dia, apriltags, scale * initial_search_factor, white_point, scale)
    end
end

"""
    track(files::AbstractVector; start::AbstractVector, stop::AbstractVector, target_width,
          start_location::AbstractVector, window_size, darker_target, fps, diagnostic_file,
          rectification, scale, …)

Use a Difference of Gaussian (DoG) filter to track a target across multiple video `files` (the
segments of one continuous run). `start`, `stop`, and `start_location` all must have the same
number of elements as `files` does. If the second, third, etc elements in `start_location` are
`missing` then the target is assumed to start where it ended in the previous video (as is the
case in segmented videos). All other keywords behave as in the single-file method, and one
diagnostic video covers all the segments.
"""
function track(
        files::AbstractVector;
        start::AbstractVector = zeros(length(files)),
        stop::AbstractVector = get_duration.(files),
        target_width::Real = 25,
        start_location::AbstractVector = similar(files, Missing),
        window_size::Union{Missing, Int, NTuple{2, Int}} = round(Int, 2target_width),
        darker_target::Bool = true,
        fps::Real = get_framerate(files[1]),
        diagnostic_file::Union{Nothing, AbstractString} = nothing,
        apriltags::Int = 0,
        initial_search_factor::Real = 4,
        scale::Real = 1,
        white_point::Real = 1, # clamped linear rescaling
        rectification = nothing
    )

    @assert length(files) == length(start) == length(stop) == length(start_location) "Array length mismatch: files=$(length(files)), start=$(length(start)), stop=$(length(stop)), start_location=$(length(start_location))"

    nfiles = length(files)
    tss = Vector{StepRangeLen{Float64, Base.TwicePrecision{Float64}, Base.TwicePrecision{Float64}, Int64}}(undef, nfiles)
    ijs = Vector{Vector{RowCol}}(undef, nfiles)
    args = tuple.(files, start, stop, start_location)

    diagnose(diagnostic_file, darker_target, rectification, fps) do dia
        end_location = missing
        for (i, (f, t_start, t_stop, loc)) in enumerate(args)
            loc = coalesce(loc, end_location)
            tss[i], ijs[i] = track_one(f, t_start, t_stop, scale*target_width, loc, round.(Int, scale .* fix_window_size(window_size)), darker_target, fps, dia, apriltags, scale * initial_search_factor, white_point, scale)
            end_location = ijs[i][end]
        end
    end
    n = sum(length, tss)
    ts = range(tss[1][1], step = step(tss[1]), length = n)
    ij = vcat(ijs...)

    return ts, ij
end

end



