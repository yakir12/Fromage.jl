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

const FACE = Ref{FTFont}()
const DEFAULT_MAX_DURATION_SECONDS = 86399.999  # 24 hours minus 1 millisecond
const RowCol = SVector{2, Float32}


function __init__()
    assets = @path joinpath(@__DIR__, "assets")
    return FACE[] = FTFont(joinpath(assets, "TeXGyreHerosMakie-Regular.otf"))
end

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
    n_bkgd = vid.nframes > 50 ? 50 : vid.nframes
    pad_indices = UnitRange.(((1 .- h)..., 1), ((sz .+ h)..., n_bkgd))
    build_stack(vid.scale, size(vid.img), n_bkgd, pad_indices)
end

populate_slice!(stack, i, vid) = copy!(selectdim(parent(parent(stack)), 3, i), vid.img)

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

function detect(guess, stack, j, h, img, radii, buff, kernel, sz, scale, bkgd_reduce = maximum)
    slice = selectdim(stack, 3, j)
    bkgd_indices = CartesianIndices(UnitRange.(guess .- h, guess .+ h)) ∩ CartesianIndices(Base.OneTo.(sz))
    img.data[bkgd_indices] .= slice[bkgd_indices] .- bkgd_reduce(stack[bkgd_indices, :], dims = 3)
    window_indices = UnitRange.(guess .- radii, guess .+ radii)
    imfilter!(CPUThreads(Algorithm.FIR()), buff, img, kernel, NoPad(), window_indices)
    v = view(buff, window_indices...)
    clamp!(v, 0, Inf)
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
    for i in axes(stack, 3)
        coords[i], guess = detect(guess, stack, i, tr.h, tr.img, tr.radii, tr.buff, tr.kernel, tr.sz, vid.scale, tr.bkgd_reduce)
        dia(selectdim(parent(parent(stack)), 3, i), round.(Int, Tuple(coords[i])))
    end
    n_bkgd = size(stack, 3)
    for i in n_bkgd + 1:vid.nframes
        next!(vid)
        j = mod1(i, n_bkgd)
        # populate_slice!(selectdim(parent(stack), 3, j), vid)
        # populate_slice!(selectdim(parent(parent(stack)), 3, j), vid)
        populate_slice!(stack, j, vid)
        coords[i], guess = detect(guess, stack, j, tr.h, tr.img, tr.radii, tr.buff, tr.kernel, tr.sz, vid.scale, tr.bkgd_reduce)
        dia(selectdim(parent(parent(stack)), 3, j), round.(Int, Tuple(coords[i])))
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

    diagnose(diagnostic_file, darker_target, rectification) do dia
        track_one(file, start, stop, scale*target_width, start_location, round.(Int, scale .* fix_window_size(window_size)), darker_target, fps, dia, apriltags, scale * initial_search_factor, white_point, scale)
    end
end

"""
    track(files::AbstractVector; start::AbstractVector, stop::AbstractVector, target_width, start_location::AbstractVector, window_size, darker_target, fps, diagnostic_file)

Use a Difference of Gaussian (DoG) filter to track a target across multiple video `files`. `start`, `stop`, and `start_location` all must have the same number of elements as `files` does. If the second, third, etc elements in `start_location` are `missing` then the target is assumed to start where it ended in the previous video (as is the case in segmented videos).
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

    diagnose(diagnostic_file, darker_target, rectification) do dia
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




# function get_p(tags, n)
#     RowCol.(reverse.(reshape(stack(getfield.(tags, :p)), 4n)))
# end
#
# function findHomography(src, dst, n)
#     # mask = Matrix{Float64}(undef, 3, 3)
#     h, mask = OpenCV.findHomography(OpenCV.Mat(reshape(reinterpret(Float32, src), 2, 4n, 1)), OpenCV.Mat(reshape(reinterpret(Float32, dst), 2, 4n, 1)))#, OpenCV.Mat(reshape(mask, 1, 3, 3)), 2000, 0.995)
#     # h, mask = OpenCV.findHomography(OpenCV.Mat(reshape(reinterpret(Float32, src), 2, 1, 4n)), OpenCV.Mat(reshape(reinterpret(Float32, dst), 2, 1, 4n)), OpenCV.RANSAC, 5.0, OpenCV.Mat(reshape(mask, 1, 3, 3)), 2000, 0.995)
#     SMatrix{3,3}(reshape(h, 3 ,3))'
# end
#
# push1 = Base.Fix2(push, 1)
#
# function track_one(file, start, stop, target_width, start_location, window_size, darker_target, fps, dia, apriltags, initial_search_factor, white_point)
#     # start and stop are taken as absolutes. To guarantee that, `ts` is set using `length` rather than the `step` key-word
#     t = stop - start
#     n = round(Int, fps * t) + 1
#     ts = range(start, stop, n)
#     indices = Vector{NTuple{2, Int}}(undef, n)
#     xys = Vector{Union{Missing, RowCol}}(undef, n)
#
#     bkgd = get_bkgd(file, start, stop)
#
#     openvideo(file; target_format = AV_PIX_FMT_GRAY8) do vid
#         vid_fps = framerate(vid)
#         if isinf(vid_fps)
#             vid_fps = get_framerate(file)
#         end
#         skip = round(Int, vid_fps / fps) - 1
#         # img = Matrix{out_frame_eltype(vid)}(undef, out_frame_size(vid))
#         img = read(vid)
#         update_ratio!(dia, size(img))
#         seek(vid, start)
#         read!(vid, img) # and do something
#         if !iszero(apriltags)
#             detector = AprilTagDetector()
#             tags = detector(collect(img))
#             if length(tags) == apriltags
#                 dst = get_p(tags, apriltags)
#                 tag = tags[1]
#                 H = inv(SMatrix{3,3}(tag.H))
#             else
#                 @error "less than $apriltags AprilTags were detected" length(tags)
#             end
#         end
#         trckr, indices[1] = get_start_ij_and_tracker(start_location, vid, img, target_width, window_size, darker_target, initial_search_factor, white_point, bkgd)
#         for i in 2:n
#             skipframes(vid, skip, throwEOF = false)
#             if eof(vid)
#                 ts = ts[1:i-1]
#                 deleteat!(indices, i:n)
#                 break
#             end
#             read!(vid, trckr.img.data)
#             indices[i] = trckr(indices[i - 1])
#             dia(trckr.img.data, indices[i])
#             if !iszero(apriltags)
#                 tags = detector(collect(trckr.img.data))
#                 if length(tags) == apriltags
#                     src = get_p(tags, apriltags)
#                     h = findHomography(src, dst, apriltags)
#                     trans = LinearMap(SDiagonal(96/2, 96/2)) ∘ pop ∘ LinearMap(H) ∘ LinearMap(h) ∘ push1 ∘ RowCol
#                     xys[i] = trans(indices[i])
#                 end
#             end
#             # @show i
#         end
#     end
#     return ts, CartesianIndex.(indices), xys
#
#     # frame_index = openvideo(open(cmd), target_format = AV_PIX_FMT_GRAY8) do vid
#     #     last_frame::Int = 1
#     #     img = read(vid)
#     #     update_ratio!(dia, size(img))
#     #     trckr, indices[1] = get_start_ij_and_tracker(start_location, vid, img, target_width, window_size, darker_target)
#     #     while !eof(vid) && last_frame < n
#     #         last_frame += 1
#     #         read!(vid, trckr.img.data)
#     #         indices[last_frame] = trckr(indices[last_frame - 1])
#     #         dia(trckr.img.data, indices[last_frame])
#     #     end
#     #     return last_frame
#     # end
#     # return ts[1:frame_index], CartesianIndex.(indices[1:frame_index])
# end


end
