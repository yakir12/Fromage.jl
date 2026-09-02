module PawsomeTracker

using ImageFiltering: Kernel, imfilter!, Algorithm, NoPad
using OffsetArrays: OffsetMatrix
using PaddedViews: PaddedView
using ..ShareIO: ShareIO
using VideoIO: openvideo, AV_PIX_FMT_GRAY8, aspect_ratio, open_video_out, VideoWriter, VideoReader, close_video_out!, skipframes, gettime
using ImageDraw: draw!, CirclePointRadius, Path
using FreeTypeAbstraction: renderstring!, FTFont
using ColorTypes: Gray
using FixedPointNumbers: N0f8
using ImageTransformations: imresize!, warp, WarpedView
using RelocatableFolders: @path
using ComputationalResources: CPU1
using DataStructures: CircularBuffer
using StaticArrays: SVector, SDiagonal
using OpenCV: OpenCV
using CoordinateTransformations: LinearMap, Transformation
using LinearAlgebra: I
using ..Rectifications: RowCol   # the one image-coordinate alias, defined where it is documented

# Confidence gate for `detect`: when the window's peak DoG response falls below GATE_FRACTION of
# the running response level, the frame is treated as "target not seen" (occlusion, glare,
# washout) and the tracker holds its last position instead of chasing the weighted mean of noise.
# The level is an exponential moving average of accepted peaks — self-normalized, so there is no
# per-video threshold to tune — and it decays slowly while holding, so a genuine, lasting drop in
# contrast eventually re-opens the gate.
const GATE_FRACTION = 0.2
const LEVEL_SMOOTH = 0.9
const GATE_DECAY = 0.99

# How many tracked frames form the rolling background model (mirrored by VerifyRuns' DEFAULTS, so
# a blank csv cell and an omitted `track` kwarg agree). Counted at the sampling rate, so the model
# spans background_length / sample_fps seconds.
const DEFAULT_BACKGROUND_LENGTH = 250

export track, ApriltagRectification, Segment, Tuning

# VideoIO.openvideo (libav's demuxer/codec open) is not thread-safe: concurrent opens race, and
# yield garbled or simply wrong frames rather than an error. Decoding independent streams IS safe,
# so only the open is serialized — every seek/read/decode stays concurrent. Guards both the
# extrinsic-frame reads (`read_frame_at`, run under `tmap`) and the per-run tracking opens (the
# `Video` constructor).
#
# This lock is also, incidentally, why tracking has never been seen to hit the share failure that
# plagues the rectification reads: it makes the opens serial, one at a time, ~0.6/s. That is a side
# effect, not the lock's purpose — do not remove it for concurrency without reading
# WHY-FRAMES-FAIL.md first.
const OPENVIDEO_LOCK = ReentrantLock()

# The open is retried like every other read of the share (see `ShareIO`). This path had no retry
# and ~372 opens per run.
#
# `transient` is widened because VideoIO reports an unreadable file, a share failure and a seek past
# the end alike as a plain `ErrorException` — there is no exit code to inspect, as there is for the
# two subprocess paths. The cost of that coarseness is that a genuinely broken file is opened three
# more times before failing; that is cheap, it fails in milliseconds, and every file reaching here
# has already been probed successfully by the gateway. The alternative is leaving the largest open
# path on the share unprotected.
#
# The lock is taken INSIDE the retried closure, so the backoff sleeps without holding it — retrying
# under the lock would stall every other open in the process for the duration.
open_gray_video(file) =
    ShareIO.withretry(; transient = ShareIO.videoio_transient) do
        lock(() -> openvideo(file; target_format = AV_PIX_FMT_GRAY8), OPENVIDEO_LOCK)
    end

# The AprilTag C detector (`apriltag_detector_detect`) is not reentrant: it has global/static state
# that concurrent calls corrupt, even across distinct per-thread detectors on distinct frames, and
# under enough pressure it segfaults. Every detection call is therefore serialized process-wide
# through this lock (see `detect_locked`), covering both calibration reference building and per-run
# tracking. Reads and decoding stay concurrent — only the detect is serial.
const APRILTAG_LOCK = ReentrantLock()

include("diagnose.jl")
include("apriltag.jl")


# The sampler advances whole frames, so the only rates it can deliver are `native_fps / skip`; this
# is the stride nearest a request, and the rate it therefore yields. The single definition both the
# sampler (`Video`) and the diagnostic writer derive from — the writer must declare a playback speed
# in terms of the rate its frames actually arrive at, not the rate that was requested (#55).
frame_skip(native_fps, sample_fps) = max(1, round(Int, native_fps / min(sample_fps, native_fps)))
effective_fps(native_fps, sample_fps) = native_fps / frame_skip(native_fps, sample_fps)

get_sigma(target_width) = target_width / 2sqrt(2log(2))

# The transpose is the point: the caller gives (width, height), the tracker wants (rows, cols).
#
# `oddify` rounds an even side up, but NOT because the kernels need an odd window, as this used to
# claim. `detect` scans `guess ± radii`, which spans `2r + 1` — odd whatever it is handed — and
# `radii` is `window_size ÷ 2`, for which `oddify(l) ÷ 2 == l ÷ 2` at every `l`. So at `scale = 1`
# and `sar = 1` it provably changes nothing. It only bites once the side is rescaled (`scale`) or
# the column extent divided (`sar`), where the extra pixel survives the rounding often enough to
# shift a radius by one — in about a fifth of sizes, and for no reason anyone can now state.
# Removing it would change tracking on scaled or anamorphic runs, so it stays until that is a
# deliberate call rather than a side effect of a comment fix.
oddify(l::Int) = l + iseven(l)
fix_window_size((w, h)::NTuple{2, Int}) = (oddify(h), oddify(w))
fix_window_size(l::Int) = (oddify(l), oddify(l))

function get_guess(start_index::RowCol, _, vid, _, _, _, _)
    guess = round.(Int, Tuple(vid.scale * start_index))
    return guess
end

function get_guess(start_xy::NTuple{2, Int}, _, vid, _, _, _, _)
    x, y = start_xy
    guess = round.(Int, vid.scale .* (y, x / vid.sar))
    return guess
end

function get_guess(::Missing, stack, vid, darker_target, target_width, initial_search_factor, subtract)
    # size the throwaway search Tracker from the stack itself, not the video: in AprilTag mode the
    # stack's canvas is the (scaled) reference viewport, which may differ from the run frame's
    sz = size(parent(stack))[1:2]
    guess = sz .÷ 2
    window_size = fix_window_size(floor(Int, min(sz...) / initial_search_factor))
    tr = Tracker(vid, darker_target, target_width, window_size, sz, subtract)
    _, guess = detect(guess, stack, 1, tr, vid.scale)
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
    sample_fps::Float64
    # `Rational{Int}`, not a bare `Rational`: the unparameterised spelling is abstract, so the field
    # would be boxed and every read of it untyped. `VideoIO.aspect_ratio` returns
    # `Union{Rational{Int32}, Rational{Int64}}` and either converts on construction. Matches
    # `VerifyRuns.Frame.sar`, which holds the same quantity read from ffprobe instead.
    sar::Rational{Int}

    # `sample_fps` arrives as a request and is stored as a promise: the sampler advances whole
    # frames, so the only rates it can deliver are `native_fps / skip`. The sample count and every
    # timestamp are derived from that EFFECTIVE rate, never from the request (#15, #17).
    #
    # `native_fps` is NOT read from the container here, though it could be. It is a verified
    # `Tuning` field — the rate the gateway probed, or the one `runs.csv` declared in its place —
    # and asking the file again would give the native rate a second definition site, the exact
    # shape of #140/#141: a run verified against one rate would then be sampled at another, and a
    # declared rate would be silently ignored by the only code that matters.
    function Video(file, native_fps, sample_fps, start, stop, scale)
        vid = open_gray_video(file)          # serialized open (openvideo isn't thread-safe); see OPENVIDEO_LOCK
        skip = frame_skip(native_fps, sample_fps)
        sample_fps = native_fps / skip       # the rate actually delivered; `sample_fps` means this from here on
        img = read(vid)
        t₀ = gettime(vid)
        # The tracked frame is the scaled one, so :width/:height are the WARPED extent, not the
        # video's. `WarpedView`'s axes depend only on `axes(img)` and the transform, so wrapping the
        # frame we already hold measures it without decoding or allocating a second one.
        height, width = size(WarpedView(img, LinearMap(1/scale); fillvalue = zero(eltype(img))))
        seek(vid, start + t₀)
        # Frames the window holds at the video's own rate, then how many of them the stride visits.
        # Sample i reads raw frame (i-1)*skip, and `cld` is exactly the count keeping that index
        # inside the window — cld(n, s) == fld(n - 1, s) + 1 — so the reads cannot run off the end.
        # The epsilon absorbs a duration that computes to 59.999999996 rather than 60; the `max`
        # makes a window shorter than one frame period yield the single frame `seek` lands on.
        navailable = max(1, floor(Int, (stop - start) * native_fps + 1e-9))
        nframes = cld(navailable, skip)
        sar = aspect_ratio(vid)
        new(vid, img, skip, nframes, scale, width, height, stop - start, sample_fps, sar)
    end
end

function video(f, file, native_fps, sample_fps, start, stop, scale)
    vid = Video(file, native_fps, sample_fps, start, stop, scale)
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
    # its own trajectory), so there the background is the per-pixel `minimum`. `nothing` means
    # background subtraction is off (background_length = 0): detect runs on the raw slice.
    bkgd_reduce::Union{Nothing, typeof(maximum), typeof(minimum)}
    # `sz` is the working-canvas size the tracker's buffers cover: the scaled frame by default, or
    # the scaled REFERENCE viewport in AprilTag mode (where the stack is registered — see
    # track_apriltag).
    function Tracker(vid, darker_target, target_width, window_size, sz = (vid.height, vid.width), subtract::Bool = true)
        # window_size arrives as (rows, cols) in display pixels; the stored frame is squeezed
        # horizontally by sar (stored x = display x / sar), so the column extent is converted to
        # stored pixels — otherwise an anamorphic (sar < 1) target fills its own search window.
        radii = (window_size[1], round(Int, window_size[2] / vid.sar)) .÷ 2
        σ = get_sigma(target_width)
        direction = darker_target ? -1 : +1
        fillvalue = zero(Gray{Float32})
        kernel = direction * Kernel.DoG((σ/vid.sar, σ))
        h = radii .+ size(kernel)

        pad_indices = UnitRange.(1 .- h, sz .+ h)
        img = PaddedView(fillvalue, Matrix{Gray{Float32}}(undef, sz...), pad_indices)
        _buff = Matrix{Float64}(undef, length.(pad_indices))
        buff = OffsetMatrix(_buff, pad_indices)
        new(img, buff, kernel, h, radii, sz, subtract ? (darker_target ? maximum : minimum) : nothing)
    end
end

# The stack stores raw frames as decoded, `Gray{N0f8}`, rather than widening them to Float32: a 4x
# saving on the largest allocation in the program (a 1080p frame at background_length = 250 is
# ~494 MB rather than ~1978 MB), losing nothing, since the values came from N0f8 to begin with. The
# SIGNED buffer is `Tracker.img`, which receives the background-subtracted frame — see `detect` (#27).
#
# At `scale = 1` — the default, and what most runs use — the transform is the identity, and the
# `WarpedView` then costs a bilinear interpolation lookup per element to return the value already
# sitting in the array. `detect` reads a whole background window (`h`-sized, times every slice)
# once per frame, so that is the package's hottest read: measured on a 79x79x250 window it is
# 24.2 ms through the warp against 5.1 ms without it, bit-identical, and ~4x on `track` end to end.
# The unit-scale stack therefore skips the layer entirely.
#
# Nothing else has to change for it. Every WRITE already reaches the storage through
# `parent(parent(stack))` (`populate_slice!`, `protect_target`, `restore_background!`), and
# `parent` of an `Array` is that array, so those keep landing on it with one layer fewer. `detect`
# indexes the stack generically and simply stops paying for the warp.
function build_stack(scale, sz, n_bkgd, pad_indices)
    isone(scale) && return PaddedView(zero(Gray{N0f8}), Array{Gray{N0f8}}(undef, sz..., n_bkgd), pad_indices)
    tform = LinearMap(SDiagonal(SVector{3, Float64}(1/scale, 1/scale, 1)))
    PaddedView(zero(Gray{N0f8}), WarpedView(Array{Gray{N0f8}}(undef, sz..., n_bkgd), tform; fillvalue = zero(Gray{N0f8})), pad_indices)
end

# Registered variant (AprilTag mode): `tform` composes each slice's registration with the inverse
# scaling (a RegisteredWarp — see apriltag.jl), so the stack's axes are the scaled REFERENCE
# viewport. They are passed explicitly because a slice-dependent transform has no meaningful
# `inv` for WarpedView's autorange.
function build_stack(tform::Transformation, canvas_sz, raw_sz, n_bkgd, pad_indices)
    inds = (Base.OneTo.(canvas_sz)..., Base.OneTo(n_bkgd))
    PaddedView(zero(Gray{N0f8}), WarpedView(Array{Gray{N0f8}}(undef, raw_sz..., n_bkgd), tform, inds; fillvalue = zero(Gray{N0f8})), pad_indices)
end

# `background_length = 0` turns background subtraction off, but the stack itself stays (it doubles
# as detect's source of the current frame) at 2 slices — 2, not 1, because a single-slice stack has
# no valid linear-interpolation stencil along the slice axis.
n_background(vid, background_length) =
    background_length == 0 ? min(2, vid.nframes) : min(background_length, vid.nframes)

function get_stack(vid, sz, h, n_bkgd::Int)
    pad_indices = UnitRange.(((1 .- h)..., 1), ((sz .+ h)..., n_bkgd))
    build_stack(vid.scale, size(vid.img), n_bkgd, pad_indices)
end

function get_stack(vid, sz, h, n_bkgd::Int, tform::Transformation)
    pad_indices = UnitRange.(((1 .- h)..., 1), ((sz .+ h)..., n_bkgd))
    build_stack(tform, sz, size(vid.img), n_bkgd, pad_indices)
end

populate_slice!(stack, i, vid) = copy!(selectdim(parent(parent(stack)), 3, i), vid.img)

# Keep the (possibly long-stationary) target OUT of the background history. The stack doubles as
# the background model and as detect's source of the current frame, so the protection happens
# AFTER detection: the frame enters the stack whole (detect must see the target), and once the
# position is known the target's search window (the same guess ± radii rectangle detect scans) in
# that slice is restored to the pre-target background the evicted frame held there. By induction
# the history never contains the target. (The prefill in collect_stack is unprotected: absorption
# needs the stationary spell to exceed the whole background window within the rolling phase.)
function protect_target(stack, j, guess, radii, scale)
    slice = selectdim(parent(parent(stack)), 3, j)
    protect = CartesianIndices(UnitRange.(round.(Int, (guess .- radii) ./ scale),
                                          round.(Int, (guess .+ radii) ./ scale))) ∩ CartesianIndices(slice)
    return protect, slice[protect]
end

# Registered variant (AprilTag mode): the search window lives in canvas (reference-space)
# coordinates, so its four corners cross `canvas2raw` — the slice's registration composed with the
# inverse scaling — before the protected region is taken as their bounding box in the raw frame.
# `pad` (raw px) absorbs the approximation: the box is computed under the INCOMING frame's
# registration while `keep` holds the EVICTED frame's raw values at those indices, each off by up
# to one frame of drone motion. Padding only widens the protected area.
function protect_target(stack, j, guess, radii, canvas2raw::Function, pad::Int)
    slice = selectdim(parent(parent(stack)), 3, j)
    corners = (canvas2raw(guess .- radii), canvas2raw(guess .+ radii),
               canvas2raw((guess[1] - radii[1], guess[2] + radii[2])),
               canvas2raw((guess[1] + radii[1], guess[2] - radii[2])))
    lo = floor.(Int, min.(corners...)) .- pad
    hi = ceil.(Int, max.(corners...)) .+ pad
    protect = CartesianIndices(UnitRange.(lo, hi)) ∩ CartesianIndices(slice)
    return protect, slice[protect]
end

function restore_background!(stack, j, protect, keep)
    selectdim(parent(parent(stack)), 3, j)[protect] = keep
    return
end

# Sequential on purpose: next!(vid) decodes into the single shared vid.img buffer, so copying
# slice i must complete before the next read.
function collect_stack(vid, sz, h, n_bkgd)
    stack = get_stack(vid, sz, h, n_bkgd)
    for i in axes(stack, 3)
        next!(vid)
        populate_slice!(stack, i, vid)
    end
    return stack
end

_weightedmean(v) = mapreduce(+, zip(Iterators.product(parentindices(v)...), v)) do (rc, w)
    RowCol(rc) * w                       # `w` is the per-element weight; `v` below is the array
end / sum(v)

# `tr` rather than seven of its fields: every call site already holds the `Tracker`, and spelling
# out `tr.h, tr.img, tr.radii, tr.buff, tr.kernel, tr.sz, tr.bkgd_reduce` at each of them is five
# copies of one list to keep in step. `Tuning` and `Segment` exist so run-level values travel as one
# typed object; this is the one hot path that undid that.
function detect(guess, stack, j, tr::Tracker, scale, level = Ref(0.0))
    h, img, radii, buff, kernel, sz, bkgd_reduce = tr.h, tr.img, tr.radii, tr.buff, tr.kernel, tr.sz, tr.bkgd_reduce
    slice = selectdim(stack, 3, j)
    bkgd_indices = CartesianIndices(UnitRange.(guess .- h, guess .+ h)) ∩ CartesianIndices(Base.OneTo.(sz))
    if isnothing(bkgd_reduce)      # subtraction off: the DoG runs on the raw slice
        img.data[bkgd_indices] .= slice[bkgd_indices]
    else
        # Widen BEFORE subtracting. A darker target makes this difference negative, and the stack's
        # `N0f8` is unsigned and wraps silently rather than erroring
        # (Gray{N0f8}(0.2) - Gray{N0f8}(0.5) == Gray{N0f8}(0.702)), which would leave the DoG
        # chasing inverted noise. `img` is Float32 precisely to hold the signed result.
        img.data[bkgd_indices] .= Gray{Float32}.(slice[bkgd_indices]) .- Gray{Float32}.(bkgd_reduce(stack[bkgd_indices, :], dims = 3))
    end
    window_indices = UnitRange.(guess .- radii, guess .+ radii)
    # Serial on purpose. This is the innermost of five nested layers of parallelism, and on a
    # 21×21 window with a 29×29 kernel the threaded resource is worth nothing measurable — see
    # DESIGN-HISTORY.md. `CPU1(FIR)` is bitwise identical to `CPUThreads(FIR)`, and the resource
    # argument cannot simply be dropped: `imfilter!` has no method taking `inds` without one.
    imfilter!(CPU1(Algorithm.FIR()), buff, img, kernel, NoPad(), window_indices)
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
    guess = Tuple(round.(Int, coord))
    return coord / scale, guess
end

function track!(coords, stack, guess, tr, vid, dia)
    level = Ref(0.0)                 # running response level for detect's confidence gate
    for i in axes(stack, 3)
        coords[i], guess = detect(guess, stack, i, tr, vid.scale, level)
        dia(selectdim(parent(parent(stack)), 3, i), round.(Int, Tuple(coords[i])))
    end
    n_bkgd = size(stack, 3)
    subtract = !isnothing(tr.bkgd_reduce)   # no background model ⇒ nothing to protect the target from
    for i in n_bkgd + 1:vid.nframes
        next!(vid)
        j = mod1(i, n_bkgd)
        # Assigned unconditionally so the restore below is guarded by the VALUE rather than by a
        # second reading of `subtract`. The two are equivalent at runtime, but only this form lets
        # the compiler see it: under the `if` the variables were merely *maybe* undefined at the
        # restore, which JET reports (and which no test could ever trip, since one flag drives both).
        protect, keep = subtract ? protect_target(stack, j, guess, tr.radii, vid.scale) : (nothing, nothing)
        populate_slice!(stack, j, vid)
        coords[i], guess = detect(guess, stack, j, tr, vid.scale, level)
        dia(selectdim(parent(parent(stack)), 3, j), round.(Int, Tuple(coords[i])))
        isnothing(protect) || restore_background!(stack, j, protect, keep)
    end
end

function track_one(file, start, stop, target_width, start_location, window_size, darker_target, native_fps, sample_fps, dia, initial_search_factor, scale, background_length)
    video(file, native_fps, sample_fps, start, stop, scale) do vid
        update_ratio!(dia, size(vid.img))
        subtract = background_length != 0
        tr = Tracker(vid, darker_target, target_width, window_size, (vid.height, vid.width), subtract)
        stack = collect_stack(vid, tr.sz, tr.h, n_background(vid, background_length))
        coords = Vector{RowCol}(undef, vid.nframes)
        guess = get_guess(start_location, stack, vid, darker_target, target_width, initial_search_factor, subtract)
        track!(coords, stack, guess, tr, vid, dia)
        # sample i is raw frame (i-1)*skip, i.e. start + (i-1)/effective_fps (#17)
        return (range(start; step = 1 / vid.sample_fps, length = vid.nframes), coords)
    end
end

"""
    Segment(file, start, stop, start_location)

One video of a run: the file, the seconds into it at which tracking starts and stops, and where the
target is at `start`, as an `(x, y)` display-pixel position.

`start_location` is `missing` on any segment whose starting position is not known independently —
the second and later segments of an ordinary run, where the target continues from where the
previous one ended, and any segment of an AprilTag run, where a missing one becomes a frame-centre
search. The first segment of an ordinary run carries a concrete one: the runs gateway resolves it
(csv cell, then the calibration's `center`, then the frame centre) before building the segment.

The union is exactly what is supported (#18). `RowCol` is absent on purpose despite having a
`get_guess` method: that is the internal form a later segment's start takes, carried over from the
previous segment's last coordinate, not something a caller supplies.
"""
struct Segment
    file::String
    start::Float64
    stop::Float64
    start_location::Union{Missing, NTuple{2, Int}}

    # `start_location` is ASSERTED by this constructor, not converted. Julia converts struct fields
    # on assignment, and Base can convert a `CartesianIndex{2}` to an `NTuple{2, Int}` — so without
    # the annotation here a (row, col) CartesianIndex would become an (x, y) start location with its
    # axes silently swapped. That is a worse version of the bug #18 was filed about (a type the
    # signature advertised but `get_guess` could not handle), and the reason the union names only
    # what `get_guess` has a method for. The other three fields convert as usual.
    Segment(file, start, stop, start_location::Union{Missing, NTuple{2, Int}}) =
        new(file, start, stop, start_location)
end

"""
    Tuning(target_width, window_size, darker_target, sample_fps, native_fps,
           initial_search_factor, scale, background_length)

The run-level tracking parameters, every one of them concrete.

Deliberately without defaults, and `track` deliberately takes no keyword arguments: each of these
values is decided in exactly one place — a csv cell, `VerifyRuns.DEFAULTS`, or the gateway's probe
of the video — and giving them a second definition here is what let a global default and a verified
value disagree, and what let an unverified value reach the tracker at all (#140, #141). A caller
with no gateway behind it (the test suite) builds one explicitly; see `tuning` in
`test/fixtures.jl`.

`window_size` is the search window scanned around the target's last known position, already imputed
(`get_window`) rather than left blank — so there is one imputation rule, upstream, instead of a
second one here.

The two rates are separate parameters and neither is derived from the other here. `native_fps` is
the rate the video itself runs at — probed once by the gateway, or declared in `runs.csv` when the
container reports it wrongly — and `sample_fps` the rate to sample it at, which the gateway has
verified does not exceed it. Both arrive concrete: tracking never opens a video merely to ask what
rate it runs at (see WHY-FRAMES-FAIL.md), and never re-derives a rate it was given.
"""
struct Tuning
    target_width::Float64
    window_size::Union{Int, NTuple{2, Int}}
    darker_target::Bool
    sample_fps::Float64
    native_fps::Float64
    initial_search_factor::Float64
    scale::Float64
    background_length::Int
end

# The default search window, when the csv leaves `window_size` blank: wide enough for the target
# itself (from its DoG sigma) and for however far it can travel between two sampled frames,
# whichever is larger. `m` is the smaller frame dimension, standing in for the distance the target
# might cross, and `duration` the run's total tracked span.
#
# Lives here, beside `Tuning`, because it is the tracker's own rule for one of its own parameters.
# It used to live in VerifyRuns while `track` carried a second, different fallback
# (`2 * target_width`) for the same field — so which window you got depended on whether you came
# through the gateway. This is now the only rule.
function get_window(target_width, sample_fps, m, duration)
    σ = get_sigma(target_width)
    ws1 = 4ceil(Int, σ) + 1 # the window the target itself needs

    speed = m / duration          # pixels per second
    distance = speed / sample_fps # distance traveled per sampled frame
    ws2 = round(Int, 2distance)

    max(ws1, ws2)
end

# Apply an image2real map over a track that may hold `missing` frames (AprilTag mode reports
# `missing` where a frame lost a tag), leaving the missings in place.
_apply_image2real(f, coords) = map(c -> ismissing(c) ? missing : f(c), coords)

# The segments' timestamps are one clock: the first segment's start and step, running to the total
# number of samples. Segments share a frame rate (see runs.md), so the step is the same throughout.
_concat_timestamps(tss) = range(tss[1][1], step = step(tss[1]), length = sum(length, tss))

"""
    track(segments::Vector{Segment}, tuning::Tuning, rectification, diagnostic_file)

Use a Difference of Gaussian (DoG) filter to track a target across the `segments` of one run,
sampling `tuning.sample_fps` frames per second (which the gateway has capped at
`tuning.native_fps`, and which is rounded here to the nearest rate reachable by skipping whole
frames — `native_fps / skip`; the returned timestamps always describe the rate actually used, never
the one requested).

Returns `(ts, coords)`: timestamps and the target's per-frame position. With a `rectification`,
`coords` are **real-world** coordinates (the rectification's `image2real` applied); with `nothing`,
they are raw `(row, col)` pixels in the original frame — `tuning.scale` trades precision for speed,
and coordinates are always reported unscaled.

An `ApriltagRectification` selects AprilTag mode (drone footage): every background-stack slice is
lazily warped into the rectification's shared reference, so drone motion is removed at lookup time
and tracking happens in a static scene. `coords` are then metric ground coordinates, `missing` on
frames where a tag was lost, and the segments do NOT chain — each registers to the same shared
reference and starts from its own `start_location` (see DESIGN-HISTORY.md). Otherwise the segments
are one continuous run, and a segment whose `start_location` is `missing` continues from where the
previous one ended.

The target is detected against a rolling background model of the last `tuning.background_length`
tracked frames (counted at the sampling rate, so the model spans
`background_length / sample_fps` seconds; memory scales with it); `background_length = 0` disables background subtraction entirely — the DoG
filter runs on the raw frame, which suits clean high-contrast scenes but lets static dark clutter
compete with the target.

Given a `diagnostic_file` (an `.mp4` path — that container selects the H.264 encoder) rather than
`nothing`, an annotated diagnostic video is written there, playing at $(DIAGNOSTIC_SPEEDUP)× real
time; a `rectification` also renders it top-down instead of as the raw frame. One diagnostic covers
every segment of the run.

There are no keyword arguments by design: everything this needs is a field of `Segment` or
`Tuning`, both of which the runs gateway fills from verified values. See `Tuning`.
"""
function track(segments::Vector{Segment}, tuning::Tuning, rectification, diagnostic_file)
    # As before (#55). The segments of a run are pieces of one recording and share their specs
    # (see runs.md), so the run's single `native_fps` describes every one of them.
    dia_fps = effective_fps(tuning.native_fps, tuning.sample_fps)

    nsegments = length(segments)
    tss = Vector{StepRangeLen{Float64, Base.TwicePrecision{Float64}, Base.TwicePrecision{Float64}, Int64}}(undef, nsegments)

    # Every segment scales these three the same way, so they are computed once rather than per
    # segment inside the loops below.
    width = tuning.scale * tuning.target_width
    window = round.(Int, tuning.scale .* fix_window_size(tuning.window_size))
    search = tuning.scale * tuning.initial_search_factor

    # AprilTag mode: every segment registers to the SAME shared reference (the tags are stationary
    # across the whole run) and is tracked independently from its own start_location, a missing one
    # falling back to the frame-centre search. Segments do not chain (see DESIGN-HISTORY.md). One
    # diagnostic spans all of them.
    if rectification isa ApriltagRectification
        segs = Vector{Vector{Union{Missing, RowCol}}}(undef, nsegments)
        dia = diagnose_apriltag(diagnostic_file, rectification.reference, tuning.darker_target, dia_fps)
        try
            for (i, s) in enumerate(segments)
                tss[i], segs[i] = track_apriltag(s.file, s.start, s.stop, width, s.start_location,
                    window, tuning.darker_target, tuning.native_fps, tuning.sample_fps, dia,
                    rectification.reference, rectification.family,
                    (rectification.height, rectification.width), search,
                    tuning.scale, tuning.background_length)
            end
        finally
            close(dia)
        end
        return (_concat_timestamps(tss), _apply_image2real(rectification.image2real, reduce(vcat, segs)))
    end

    ijs = Vector{Vector{RowCol}}(undef, nsegments)
    diagnose(diagnostic_file, tuning.darker_target, rectification, dia_fps) do dia
        end_location = missing
        for (i, s) in enumerate(segments)
            loc = coalesce(s.start_location, end_location)
            tss[i], ijs[i] = track_one(s.file, s.start, s.stop, width, loc, window,
                tuning.darker_target, tuning.native_fps, tuning.sample_fps, dia, search,
                tuning.scale, tuning.background_length)
            end_location = ijs[i][end]
        end
    end
    ts = _concat_timestamps(tss)
    ij = vcat(ijs...)

    # Real-world coordinates when a rectification is given, else pixels. This stays `map`, not
    # `_apply_image2real`: no coordinate here can be `missing`, and routing it through the
    # missing-tolerant version would widen the returned element type to `Union{Missing, …}` for
    # every ordinary rectified run.
    return isnothing(rectification) ? (ts, ij) : (ts, map(rectification.image2real, ij))
end

end
