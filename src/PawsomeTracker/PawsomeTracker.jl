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
using ..Spaces: GroundXY, RowCol, stored_x, to_stored

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

# The open is retried like every other read of the share (see `ShareIO`). This path had no retry,
# and it is ONE open per run — ~372 of them in the reference session, which has 372 runs
# (CIFS-SHARE-INVESTIGATION.md). This used to read "~372 opens per run", which is the ratio
# backwards by a factor of 372.
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
# through this lock (see `detect_locked`), covering both rectification reference building and per-run
# tracking. Reads and decoding stay concurrent — only the detect is serial.
const APRILTAG_LOCK = ReentrantLock()

# Cleanup on a failing path, for both native resources this module owns: the diagnostic writer
# (#160) and the video reader (#149). An exception raised inside a `finally` silently replaces the
# one already on its way out — the one that explains what went wrong — so a close that fails says
# so in a warning instead of in the caller's stacktrace.
#
# Deliberately broad, in the same shape as the precompile workloads and `save_issue_frame`: what
# ffmpeg and the filesystem report here is a plain `ErrorException`/`IOError` with nothing narrower
# to match on, and the point is precisely that NOTHING from cleanup reaches the caller. The
# exception is not lost — it goes to the log, with its backtrace. Ctrl-C still gets through. The
# cost is that a `MethodError` from a bug in here is demoted to a warning too (DECISIONS, "No bare
# `catch`").
function warn_on_failure(step!, what)
    try
        step!()
    catch e
        e isa InterruptException && rethrow()
        @warn "could not $what while cleaning up after an earlier failure" exception = (e, catch_backtrace())
    end
    return nothing
end

include("types.jl")
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
# `radii` is `window_size ÷ 2`, for which `oddify(l) ÷ 2 == l ÷ 2` at every `l`. So at
# `downscale = 1` and `sar = 1` it provably changes nothing. It only bites once the side is rescaled
# (`downscale`) or the column extent divided (`sar`), where the extra pixel survives the rounding
# often enough to shift a radius by one — in about a fifth of sizes, and for no reason anyone can now state.
# Removing it would change tracking on scaled or anamorphic runs, so it stays until that is a
# deliberate call rather than a side effect of a comment fix.
oddify(l::Int) = l + iseven(l)
fix_window_size((w, h)::NTuple{2, Int}) = (oddify(h), oddify(w))
fix_window_size(l::Int) = (oddify(l), oddify(l))

function get_guess(start_index::RowCol, _, vid, _, _, _, _)
    guess = round.(Int, Tuple(vid.downscale * start_index))
    return guess
end

function get_guess(start_xy::NTuple{2, Int}, _, vid, _, _, _, _)
    guess = round.(Int, vid.downscale .* to_stored(start_xy, vid.sar))
    return guess
end

function get_guess(::Missing, stack, vid, darker_target, target_width, initial_search_factor, subtract)
    # size the throwaway search Tracker from the stack itself, not the video: in AprilTag mode the
    # stack's canvas is the (scaled) reference viewport, which may differ from the run space's
    sz = size(parent(stack))[1:2]
    guess = sz .÷ 2
    window_size = fix_window_size(floor(Int, min(sz...) / initial_search_factor))
    tr = Tracker(vid, darker_target, target_width, window_size, sz, subtract)
    _, guess = detect(guess, stack, 1, tr, vid.downscale)
    return guess
end

struct Video
    vid::VideoReader
    img::PermutedDimsArray{Gray{N0f8}, 2, (2, 1), (2, 1), Matrix{Gray{N0f8}}}
    skip::Int
    nframes::Int
    downscale::Float64
    width::Int
    height::Int
    sample_fps::Float64
    # `Rational{Int}`, not a bare `Rational`: the unparameterised spelling is abstract, so the field
    # would be boxed and every read of it untyped. `VideoIO.aspect_ratio` returns
    # `Union{Rational{Int32}, Rational{Int64}}` and either converts on construction. Matches
    # `VerifyRuns.FrameFormat.sar`, which holds the same quantity read from ffprobe instead.
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
    # The reader is opened first and every step below it can throw, so the open is guarded rather
    # than moved: unlike the diagnostic writer's constructor (#160), the fallible work here IS the
    # reader — `read`, `gettime`, `seek`, `aspect_ratio`, and the `WarpedView` extent measured on
    # the frame `read` returned — and those are exactly the calls the share fails
    # (WHY-FRAMES-FAIL.md). Without the guard each failure leaked a descriptor and a decoder
    # context, and tracking opens one reader per segment under `tmap` (#149).
    #
    # A successfully built `Video` still hands its reader to the caller to close — see `video`,
    # which is the only thing that should be constructing one.
    function Video(file, native_fps, sample_fps, start, stop, downscale)
        vid = open_gray_video(file)          # serialized open (openvideo isn't thread-safe); see OPENVIDEO_LOCK
        built = false
        return try
            skip = frame_skip(native_fps, sample_fps)
            sample_fps = native_fps / skip       # the rate actually delivered; `sample_fps` means this from here on
            img = read(vid)
            t₀ = gettime(vid)
            # The tracked frame is the scaled one, so :width/:height are the WARPED extent, not the
            # video's. `WarpedView`'s axes depend only on `axes(img)` and the transform, so wrapping the
            # frame we already hold measures it without decoding or allocating a second one.
            height, width = size(WarpedView(img, LinearMap(1/downscale); fillvalue = zero(eltype(img))))
            seek(vid, start + t₀)
            # Frames the window holds at the video's own rate, then how many of them the stride visits.
            # Sample i reads raw frame (i-1)*skip, and `cld` is exactly the count keeping that index
            # inside the window — cld(n, s) == fld(n - 1, s) + 1 — so the reads cannot run off the end.
            # The epsilon absorbs a duration that computes to 59.999999996 rather than 60; the `max`
            # makes a window shorter than one frame period yield the single frame `seek` lands on.
            navailable = max(1, floor(Int, (stop - start) * native_fps + 1e-9))
            nframes = cld(navailable, skip)
            sar = aspect_ratio(vid)
            v = new(vid, img, skip, nframes, downscale, width, height, sample_fps, sar)
            built = true
            v
        finally
            # A flag rather than a `catch`, as in `Diagnostic` (#160): `finally` cannot tell success
            # from failure on its own, and this keeps a catch-everything out of the package.
            built || warn_on_failure(() -> close(vid), "close the video reader")
        end
    end
end

# Guarded like the constructor's own close, and over a wider window: `f` here is the whole tracking
# run, so a close that threw on top of a failed run would replace the exception explaining the run.
function video(f, file, native_fps, sample_fps, start, stop, downscale)
    vid = Video(file, native_fps, sample_fps, start, stop, downscale)
    return try
        f(vid)
    finally
        warn_on_failure(() -> close(vid.vid), "close the video reader")
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
        # horizontally, so the COLUMN extent — and only it — is converted to stored pixels by
        # `stored_x`, otherwise an anamorphic (sar < 1) target fills its own search window.
        radii = (window_size[1], round(Int, stored_x(window_size[2], vid.sar))) .÷ 2
        σ = get_sigma(target_width)
        direction = darker_target ? -1 : +1
        fillvalue = zero(Gray{Float32})
        # `Kernel.DoG` takes its sigmas in array order, (rows, cols), so the sar correction belongs
        # on the SECOND one — the same column axis `radii` corrects above. It was on the first,
        # which stretched the matched filter across the rows while the anamorphic squeeze stretches
        # the columns: at sar 1/2 a target 9 rows by 18 columns was hunted with a 53x29 filter.
        # `h` below adds these two elementwise, so they must share an axis order (#36).
        kernel = direction * Kernel.DoG((σ, σ/vid.sar))
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
# At `downscale = 1` — the default, and what most runs use — the transform is the identity, and the
# `WarpedView` then costs a bilinear interpolation lookup per element to return the value already
# sitting in the array. `detect` reads a whole background window (`h`-sized, times every slice)
# once per frame, so that is the package's hottest read: measured on a 79x79x250 window it is
# 24.2 ms through the warp against 5.1 ms without it, bit-identical, and ~4x on `track` end to end.
# The stack at `downscale = 1` therefore skips the layer entirely.
#
# Nothing else has to change for it. Every WRITE already reaches the storage through
# `parent(parent(stack))` (`populate_slice!`, `protect_target`, `restore_background!`), and
# `parent` of an `Array` is that array, so those keep landing on it with one layer fewer. `detect`
# indexes the stack generically and simply stops paying for the warp.
function build_stack(downscale, sz, n_bkgd, pad_indices)
    isone(downscale) && return PaddedView(zero(Gray{N0f8}), Array{Gray{N0f8}}(undef, sz..., n_bkgd), pad_indices)
    tform = LinearMap(SDiagonal(SVector{3, Float64}(1/downscale, 1/downscale, 1)))
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
    build_stack(vid.downscale, size(vid.img), n_bkgd, pad_indices)
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
function protect_target(stack, j, guess, radii, downscale)
    slice = selectdim(parent(parent(stack)), 3, j)
    protect = CartesianIndices(UnitRange.(round.(Int, (guess .- radii) ./ downscale),
                                          round.(Int, (guess .+ radii) ./ downscale))) ∩ CartesianIndices(slice)
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
function detect(guess, stack, j, tr::Tracker, downscale, level = Ref(0.0))
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
    # DECISIONS.md. `CPU1(FIR)` is bitwise identical to `CPUThreads(FIR)`, and the resource
    # argument cannot simply be dropped: `imfilter!` has no method taking `inds` without one.
    imfilter!(CPU1(Algorithm.FIR()), buff, img, kernel, NoPad(), window_indices)
    v = view(buff, window_indices...)
    clamp!(v, 0, Inf)
    # the confidence gate (see GATE_FRACTION above): hold the last position when the response
    # collapses to noise, rather than wander after the weighted mean of nothing
    peak = maximum(v)
    if peak < GATE_FRACTION * level[]
        level[] *= GATE_DECAY
        return RowCol(guess) / downscale, guess
    end
    level[] = level[] == 0 ? peak : LEVEL_SMOOTH * level[] + (1 - LEVEL_SMOOTH) * peak
    coord = _weightedmean(v)
    if any(isnan, coord)
        return RowCol(guess) / downscale, guess
    end
    guess = Tuple(round.(Int, coord))
    return coord / downscale, guess
end

function track!(coords, stack, guess, tr, vid, dia)
    level = Ref(0.0)                 # running response level for detect's confidence gate
    for i in axes(stack, 3)
        coords[i], guess = detect(guess, stack, i, tr, vid.downscale, level)
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
        protect, keep = subtract ? protect_target(stack, j, guess, tr.radii, vid.downscale) : (nothing, nothing)
        populate_slice!(stack, j, vid)
        coords[i], guess = detect(guess, stack, j, tr, vid.downscale, level)
        dia(selectdim(parent(parent(stack)), 3, j), round.(Int, Tuple(coords[i])))
        isnothing(protect) || restore_background!(stack, j, protect, keep)
    end
end

# `dia` is a `Diagnostic`/`Dont` created and closed by the caller, shared across a run's segments.
#
# Four arguments, all of different types, rather than the thirteen this used to unpack out of the
# caller's `ResolvedSegment`/`Tuning` and repack here. Six of those thirteen were bare `Float64`s
# and a transposition among them compiled and returned a wrong track: swapping `target_width` with
# `initial_search_factor` at the call site passed the entire tracker suite (#201 follow-up).
function track_one(rseg::ResolvedSegment, tuning::Tuning, scaled::ScaledTuning, dia)
    video(rseg.file, tuning.native_fps, tuning.sample_fps, rseg.start, rseg.stop, tuning.downscale) do vid
        update_ratio!(dia, size(vid.img))
        subtract = tuning.background_length != 0
        tr = Tracker(vid, tuning.darker_target, scaled.width, scaled.window, (vid.height, vid.width), subtract)
        stack = collect_stack(vid, tr.sz, tr.h, n_background(vid, tuning.background_length))
        coords = Vector{RowCol}(undef, vid.nframes)
        guess = get_guess(rseg.start_location, stack, vid, tuning.darker_target, scaled.width, scaled.search, subtract)
        track!(coords, stack, guess, tr, vid, dia)
        # sample i is raw frame (i-1)*skip, i.e. start + (i-1)/effective_fps (#17)
        return (range(rseg.start; step = 1 / vid.sample_fps, length = vid.nframes), coords)
    end
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
#
# Each segment's own `start` is therefore dropped: it is a time in ITS file, and only the first
# segment's file anchors the run. What lies between two segments — a stretch cut out of one file,
# or the join between two files — is closed up, and the track carries no sign of it. That is the
# documented normalization, not an oversight: the removed time is recoverable from `runs.csv`, and
# the track and any speed derived from it ignore it deliberately (DECISIONS, #153).
_concat_timestamps(tss) = range(tss[1][1], step = step(tss[1]), length = sum(length, tss))

"""
    track(segments::Vector{Segment}, tuning::Tuning, rectification, diagnostic_file)

Use a Difference of Gaussian (DoG) filter to track a target across the `segments` of one run,
sampling `tuning.sample_fps` frames per second (which the gateway has capped at
`tuning.native_fps`, and which is rounded here to the nearest rate reachable by skipping whole
frames — `native_fps / skip`; the returned timestamps always describe the rate actually used, never
the one requested).

Returns `(ts, coords)`: timestamps and the target's per-frame position. `ts` is the run's one clock
— the first segment's `start`, one sampling interval per tracked frame — so a later segment's own
`start` (a time in its own file) does not appear in it, and time left out between segments is closed
up. With a `rectification`,
`coords` are **real-world** coordinates (the rectification's `image2real` applied); with `nothing`,
they are raw `(row, col)` pixels in the original frame — `tuning.downscale` trades precision for
speed, and coordinates are always reported unscaled.

An `ApriltagRectification` selects AprilTag mode (drone footage): every background-stack slice is
lazily warped into the rectification's shared reference, so drone motion is removed at lookup time
and tracking happens in a static scene. `coords` are then ground coordinates in the rectification's real-world unit, `missing` on
frames where a tag was lost, and the segments do NOT chain — each registers to the same shared
reference and starts from its own `start_location` (see DECISIONS.md). Otherwise the segments
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

    # Every segment scales these the same way, so they are computed once rather than per segment
    # inside the loops below — which is what `ScaledTuning` is for.
    scaled = ScaledTuning(tuning)

    # AprilTag mode: every segment registers to the SAME shared reference (the tags are stationary
    # across the whole run) and is tracked independently from its own start_location, a missing one
    # falling back to the frame-centre search. Segments do not chain (see DECISIONS.md). One
    # diagnostic spans all of them.
    if rectification isa ApriltagRectification
        # `GroundXY` (the same type as `RowCol`, see Spaces): what track_apriltag returns is metric
        # ground (x, y), and the gauge below is what turns it into real coordinates.
        segs = Vector{Vector{Union{Missing, GroundXY}}}(undef, nsegments)
        diagnose_apriltag(diagnostic_file, rectification, tuning.darker_target, dia_fps) do dia
            for (i, s) in enumerate(segments)
                # The `Segment` itself, unresolved: nothing chains here, so its start_location
                # is already final — what the csv said, or `missing` for a centre search.
                tss[i], segs[i] = track_apriltag(s, tuning, scaled, dia, rectification)
            end
        end
        return (_concat_timestamps(tss), _apply_image2real(rectification.image2real, reduce(vcat, segs)))
    end

    ijs = Vector{Vector{RowCol}}(undef, nsegments)
    diagnose(diagnostic_file, tuning.darker_target, rectification, dia_fps) do dia
        end_location = missing
        for (i, s) in enumerate(segments)
            # The chaining: a segment with no start_location of its own continues from where the
            # previous one ended. That carried-over value is a `RowCol`, which a `Segment` cannot
            # hold (#18) — hence `ResolvedSegment`, whose union names exactly what `get_guess` takes.
            rseg = ResolvedSegment(s.file, s.start, s.stop, coalesce(s.start_location, end_location))
            tss[i], ijs[i] = track_one(rseg, tuning, scaled, dia)
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
