# The synthetic media every suite runs against — ffmpeg-encoded videos and the analytic ground
# truth that comes with them — plus the ffprobe readers used to assert on produced videos.
#
# A module rather than an `include`d file: the four suites share one compiled copy, and generators
# here can be shared without any of them reaching into another's scope.
module Fixtures

using FFMPEG: FFMPEG
using Statistics: mean
using AprilTags: getAprilTagImage, tag36h11
using StaticArrays: SVector, SMatrix
using Fromage.PawsomeTracker: PawsomeTracker, Segment, Tuning, get_window, track

export make_video, make_checkerboard_video, make_corrupt_video, make_target_video,
    tracking_rmse, probe_stream, probe_frames,
    make_apriltag_video, drone_pose, apriltag_ground, render_pose, pose_apply,
    tuning, segments, track1

# ---------------------------------------------------------------------------
# Video artifacts.
# ---------------------------------------------------------------------------

function make_video(path; duration = 5, size = (640, 480), rate = 30)
    w, h = size
    FFMPEG.ffmpeg_exe(`-y -loglevel error -f lavfi -i testsrc=duration=$duration:size=$(w)x$(h):rate=$rate -pix_fmt yuv420p $path`)
    path
end

function make_checkerboard_video(path, png; duration = 5)
    pad = "pad=ceil(iw/2)*2:ceil(ih/2)*2"   # libx264/yuv420p needs even dimensions
    FFMPEG.ffmpeg_exe(`-y -loglevel error -framerate 10 -loop 1 -i $png -t $duration -vf $pad -pix_fmt yuv420p $path`)
    path
end

# A file ffprobe reliably refuses: the leading bytes of a real mp4, with the moov atom and all the
# media data cut off. Deterministic on purpose — the "ffprobe exits 0 but reports nothing usable"
# case is covered deliberately by the audio-only fixture in test/probing.jl, so this one always
# exercises the outright-unreadable path.
function make_corrupt_video(path)
    mktempdir() do dir
        whole = joinpath(dir, "whole.mp4")
        make_video(whole; duration = 1, size = (64, 64), rate = 5)
        write(path, read(whole)[1:500])
    end
    return path
end

# A disc whose display-space center follows x(N) = col − A·sin(0.5π·N/fps), y(N) = row (ffmpeg
# 0-based coordinates, A = width/2.5), drawn by ffmpeg's geq expression at width×height square
# pixels, then squeezed to (width/sar)×height stored pixels with setsar=sar — a genuinely
# anamorphic file when sar ≠ 1. `nsegments > 1` splits the same trajectory into several files on
# forced keyframes (a segmented run). `pause = (t1, t2)` freezes the trajectory between those
# seconds — a long-stationary target, which the background model must not absorb. Writes into
# `dir`; returns the basename(s) and the ground-truth closure `expected(i; skip, offset)`: the
# stored-frame 1-based (row, col) of the disc center at sample i, where sample i reads global frame
# `offset + (i − 1)·skip` (skip = video fps ÷ requested fps).
function make_target_video(dir, name; width = 100, height = 100, sar = 1//1, fps = 25, duration = 2,
        target_width = 10, darker_target = true, row = 50, col = 55, nsegments = 1, pause = nothing)
    A = width / 2.5
    target_c, bkgd_c = darker_target ? (0, 255) : (255, 0)
    w2 = round(Int, width / sar)
    sarg = "$(numerator(sar))/$(denominator(sar))"
    # the frame index driving the trajectory: identity, or frozen at p1 for the pause's span
    p1, p2 = isnothing(pause) ? (0, 0) : round.(Int, pause .* fps)
    Nexpr = isnothing(pause) ? "N" : "if(lt(N,$p1),N,if(lt(N,$p2),$p1,N-($p2-$p1)))"
    freeze(N) = isnothing(pause) ? N : (N < p1 ? N : (N < p2 ? p1 : N - (p2 - p1)))
    vf = "geq=lum='if(lt(sqrt((X-$col+$A*sin(0.5*PI*($Nexpr)/$fps))^2+(Y-$row)^2),$(target_width/2)),$target_c,$bkgd_c)':cb=128:cr=128,scale=$w2:$height,setsar=$sarg"
    # -qp 0: lossless — the analytic ground truth stays exact, with no encoder noise around the disc
    src = `-y -loglevel error -f lavfi -i color=white:s=$(width)x$(height):d=$duration:r=$fps -vf $vf -pix_fmt yuv420p -qp 0`
    files = if nsegments == 1
        FFMPEG.ffmpeg_exe(`$src $(joinpath(dir, "$name.mp4"))`)
        ["$name.mp4"]
    else
        T = duration / nsegments
        kf = "expr:gte(t,n_forced*$T)"
        FFMPEG.ffmpeg_exe(`$src -force_key_frames $kf -f segment -segment_time $T $(joinpath(dir, name * "_%02d.mp4"))`)
        [string(name, "_", lpad(k, 2, '0'), ".mp4") for k in 0:(nsegments - 1)]
    end
    expected = (i; skip = 1, offset = 0) -> begin
        N = freeze(offset + (i - 1) * skip)
        (row + 1.0, (col - A * sin(0.5π * N / fps)) / sar + 1)
    end
    return files, expected
end

"RMSE (in stored-frame pixels) between tracked coordinates and the ground-truth closure."
function tracking_rmse(ij, expected; skip = 1, offset = 0)
    sqrt(mean([sum(abs2, Tuple(rc) .- expected(i; skip, offset)) for (i, rc) in enumerate(ij)]))
end

# ---------------------------------------------------------------------------
# AprilTag drone footage.
# ---------------------------------------------------------------------------
#
# One static ground plane carrying four tags and a moving disc, filmed by a drone whose pose
# changes every frame. The drone's motion is expressed as a `ground -> image` homography per
# frame, and the frame is rendered by looking that homography up backwards — which makes the
# whole fixture analytic: the disc's image position is `pose_apply(H_k, ground_xy(k))`, and its
# position in the REFERENCE frame is `pose_apply(H_1, ground_xy(k))` no matter what `H_k` is.
# That last invariant is the ground truth the AprilTag pipeline is measured against, since
# registration exists precisely to cancel `H_k`.

# `pose_apply` is deliberately a local re-implementation of the source's `apply_h` rather than an
# import of it: this is the ground truth the source is checked against, so it must not be able to
# fail in step with the code under test.
pose_apply(H, p) = (v = H * SVector(Float64(p[1]), Float64(p[2]), 1.0); SVector(v[1] / v[3], v[2] / v[3]))

# Ground layout, in ground-canvas pixels. `getAprilTagImage` returns the 10x10 cell image — the
# 8x8 black-border square plus one white quiet-zone cell all round — so each tag block is
# 10 * TAG_CELL px square. TAG_CELL is also what the calibs row declares as `tag_cell_width`, which
# makes one recovered metric unit exactly one ground pixel and the tracked cm path therefore
# directly comparable to the intended ground path.
const TAG_CELL = 8
const TAG_BLOCKS = [(150, 150), (150, 370), (370, 150), (370, 370)]   # (row, col) of each block

"The static ground plane: white, with tag36h11 ids 0:3 burned in at `TAG_BLOCKS`."
function apriltag_ground(GH = 600, GW = 600)
    upscale(t) = UInt8.(kron(Int.(t), ones(Int, TAG_CELL, TAG_CELL)))
    tagu8(id) = UInt8.(255 .* (Float64.(getAprilTagImage(id, tag36h11)) .> 0.5))
    ground = fill(0xff, GH, GW)
    for ((r, c), id) in zip(TAG_BLOCKS, 0:3)
        ground[r+1:r+10TAG_CELL, c+1:c+10TAG_CELL] .= upscale(tagu8(id))
    end
    return ground
end

# A drone pose, as the image-space motion it induces, composed from interpretable degrees of
# freedom about the fixed point `(cx, cy)` — pass the frame centre for the rotations a drone
# actually makes. A planar scene can only ever be seen through a homography, and these knobs reach
# every one such a camera produces: the six rigid-body degrees of freedom, plus skew.
# (A full homography has eight; the eighth is non-uniform scale, which a camera with square pixels
# cannot produce, so it is deliberately absent rather than overlooked.)
#
#   dx, dy  translation (px)          the drone flying over the ground   (x, y)
#   zoom    uniform scale             altitude                           (z)
#   yaw     in-plane rotation (rad)   spinning about the vertical axis
#   pitch   projective tilt (rad)     nose up/down: the far ground edge converges
#   roll    projective tilt (rad)     banking left/right
#   shear   pure skew                 not a drone DOF at all; a separate knob so skew can be
#                                     exercised on its own rather than only where a physical
#                                     pose happens to induce it
#
# pitch/roll enter through the projective row `[px py 1]`. For a nadir camera at height `alt` px,
# a tilt of `phi` induces `tan(phi) / alt`, so a test can ask for "12 degrees of pitch" and get a
# displacement of the right physical size instead of a bare 3e-4.
function drone_pose(; dx = 0.0, dy = 0.0, zoom = 1.0, yaw = 0.0, pitch = 0.0, roll = 0.0,
                      shear = 0.0, alt = 1000.0, cx = 0.0, cy = 0.0)
    # NB StaticArrays' constructor is COLUMN-major; each line below is one column.
    T(x, y) = SMatrix{3, 3, Float64}(1, 0, 0, 0, 1, 0, x, y, 1)
    R = SMatrix{3, 3, Float64}(cos(yaw), sin(yaw), 0, -sin(yaw), cos(yaw), 0, 0, 0, 1)
    S = SMatrix{3, 3, Float64}(zoom, 0, 0, 0, zoom, 0, 0, 0, 1)
    K = SMatrix{3, 3, Float64}(1, 0, 0, shear, 1, 0, 0, 0, 1)
    P = SMatrix{3, 3, Float64}(1, 0, tan(roll) / alt, 0, 1, tan(pitch) / alt, 0, 0, 1)
    H = T(cx + dx, cy + dy) * P * S * R * K * T(-cx, -cy)
    return H / H[3, 3]
end

# Render one frame: for every image pixel, find where it came from on the ground plane
# (`inv(H)`) and sample there, bilinearly, so tag edges stay smooth under a non-integer transform
# and the detector keeps its sub-pixel corner accuracy. An integer translation reduces to an exact
# pixel copy, which is what keeps a plain-pan fixture bit-identical to the crop it used to be.
# Reads off the canvas return the background white.
function render_pose(ground, H, height, width)
    Hinv = inv(H)
    out = Matrix{UInt8}(undef, height, width)
    GH, GW = size(ground)
    @inbounds for j in 1:width, i in 1:height
        v = Hinv * SVector(Float64(j), Float64(i), 1.0)
        x = v[1] / v[3]
        y = v[2] / v[3]
        x0 = floor(Int, x)
        y0 = floor(Int, y)
        if x0 < 1 || y0 < 1 || x0 >= GW || y0 >= GH
            out[i, j] = 0xff
            continue
        end
        fx = x - x0
        fy = y - y0
        out[i, j] = round(UInt8, (1 - fy) * ((1 - fx) * ground[y0, x0] + fx * ground[y0, x0+1]) +
                                      fy  * ((1 - fx) * ground[y0+1, x0] + fx * ground[y0+1, x0+1]))
    end
    return out
end

# The disc, burned into a copy of the ground plane at ground position `(r0, c0)`.
function draw_disc(ground, r0, c0, tw)
    g = copy(ground)
    rad = tw / 2
    for i in floor(Int, r0 - rad):ceil(Int, r0 + rad), j in floor(Int, c0 - rad):ceil(Int, c0 + rad)
        (i - r0)^2 + (j - c0)^2 <= rad^2 && (g[i, j] = 0x00)
    end
    return g
end

"""
    make_apriltag_video(dir, name; kwargs...)

A synthetic drone flight over four stationary tag36h11 tags: a dark disc travels a known straight
line across the ground plane while the drone pose changes every frame. Encoded losslessly (`-qp 0`)
so the tags stay crisp for detection.

`pose(k)` supplies frame `k`'s image-space drone motion (a 3x3 homography, e.g. from `drone_pose`),
composed onto the fixed crop that places the `height` x `width` frame in the middle of the
`GH` x `GW` ground canvas. The default is the legacy circular pan of amplitude `amp` px — pure
translation, and bit-identical to the crop it used to be implemented as. Frames listed in
`occlude` get the first tag painted over, so that frame cannot register.

Returns a NamedTuple; its first four fields are positional-destructuring compatible with the
older `(file, groundpath, start_location, nframes)` form.

  * `file`           the video's basename in `dir`
  * `groundpath`     the disc's `(row, col)` on the ground canvas, per frame
  * `start_location` the disc's `(x, y)` in frame 1, as the runs CSV wants it
  * `nframes`
  * `expected_ref(k)` the disc's `(x, y)` in the REFERENCE frame (frame 1) at frame `k`. Independent
    of `pose`, because registration is supposed to cancel it — this is the ground truth a tracked
    cm coordinate is checked against, via `pose_apply(ref.M, expected_ref(k))`.
  * `poses[k]`       frame `k`'s full ground -> image homography
  * `image_xy(k)`    the disc's true `(x, y)` in frame `k` itself
"""
function make_apriltag_video(dir, name; H = 480, W = 480, GH = 600, GW = 600,
                             nframes = 60, fps = 25, tw = 12, amp = 40, pose = nothing,
                             occlude = Int[])
    ox0, oy0 = (GW - W) ÷ 2, (GH - H) ÷ 2                   # the fixed crop: ground -> frame
    turn(k) = 2π * (k - 1) / nframes
    # The default flight is the legacy circular pan, expressed as a pose. Its offsets are rounded
    # exactly as the crop used to round them (`round(Int, ox0 + amp*cos)`, not `ox0 + round(...)`
    # — those differ on a tie), so the render stays an exact pixel copy of that crop.
    poses = if isnothing(pose)
        [drone_pose(dx = -round(Int, ox0 + amp * cos(turn(k))),
                    dy = -round(Int, oy0 + amp * sin(turn(k)))) for k in 1:nframes]
    else
        base = drone_pose(dx = -ox0, dy = -oy0)
        [pose(k) * base for k in 1:nframes]                 # `pose` moves the drone about the frame
    end

    gr(k) = 260.0 + 40 * (k - 1) / (nframes - 1)           # disc ground path (row, col): a line
    gc(k) = 260.0 + 60 * (k - 1) / (nframes - 1)
    ground_xy(k) = SVector(gc(k), gr(k))                    # the same point as (x, y)

    ground = apriltag_ground(GH, GW)
    occluded = copy(ground)
    r, c = TAG_BLOCKS[1]
    occluded[r+1:r+10TAG_CELL, c+1:c+10TAG_CELL] .= 0xff    # the first tag painted out
    raw = joinpath(dir, "$name.raw")
    open(raw, "w") do io
        for k in 1:nframes
            g = draw_disc(k in occlude ? occluded : ground, gr(k), gc(k), tw)
            write(io, vec(permutedims(render_pose(g, poses[k], H, W))))   # row-major for ffmpeg
        end
    end
    FFMPEG.ffmpeg_exe(`-y -loglevel error -f rawvideo -pix_fmt gray -s $(W)x$(H) -r $fps -i $raw -pix_fmt yuv420p -qp 0 $(joinpath(dir, "$name.mp4"))`)
    rm(raw)

    expected_ref = k -> pose_apply(poses[1], ground_xy(k))
    image_xy = k -> pose_apply(poses[k], ground_xy(k))
    return (; file = "$name.mp4",
              groundpath = [(gr(k), gc(k)) for k in 1:nframes],
              start_location = Tuple(round.(Int, expected_ref(1))),
              nframes, expected_ref, poses, image_xy, ground_xy)
end

# ---------------------------------------------------------------------------
# Video probing (ffprobe) — for asserting on produced (diagnostic) videos.
# ---------------------------------------------------------------------------

"Facts of `file`'s first video stream: frame size, real frame count, declared fps, duration
(NaN when the container doesn't store one, e.g. MPEG-TS)."
function probe_stream(file)
    fields = Dict{String, String}()
    for l in eachline(pipeline(`$(FFMPEG.ffprobe()) -v error -select_streams v:0 -count_frames -show_entries stream=width,height,nb_read_frames,avg_frame_rate,duration -of default=noprint_wrappers=1 $file`))
        isempty(l) && continue
        k, v = split(l, '='; limit = 2)
        fields[k] = v
    end
    num, den = parse.(Int, split(fields["avg_frame_rate"], '/'))
    return (; width = parse(Int, fields["width"]), height = parse(Int, fields["height"]),
        nframes = parse(Int, fields["nb_read_frames"]), fps = num / den,
        duration = something(tryparse(Float64, get(fields, "duration", "")), NaN))
end

"Per-frame sizes (a Set of (w, h)) plus the packet PTS and DTS sequences in file (= decode)
order — for asserting a single resolution and sane timestamps across concatenated segments.
Note B-frames make PTS legitimately non-monotonic in decode order; DTS must be monotonic and
every PTS unique."
function probe_frames(file)
    sizes = Set{NTuple{2, Int}}()
    for l in eachline(pipeline(`$(FFMPEG.ffprobe()) -v error -select_streams v:0 -show_frames -show_entries frame=width,height -of csv=p=0 $file`))
        isempty(l) && continue
        w, h = parse.(Int, split(l, ',')[1:2])
        push!(sizes, (w, h))
    end
    pts = Int[]
    dts = Int[]
    for l in eachline(pipeline(`$(FFMPEG.ffprobe()) -v error -select_streams v:0 -show_entries packet=pts,dts -of csv=p=0 $file`))
        isempty(l) && continue
        parts = split(l, ',')
        push!(pts, parse(Int, parts[1]))
        push!(dts, parse(Int, parts[2]))
    end
    return sizes, pts, dts
end


# ---------------------------------------------------------------------------
# Tracking inputs.
# ---------------------------------------------------------------------------

# `PawsomeTracker.track` takes no keyword arguments: every tunable is a field of a `Tuning` and
# every per-video value a field of a `Segment`, both of which the runs gateway fills from verified
# csv values. Tests are the only caller with no gateway behind them, so the convenience lives HERE,
# in the scaffolding, rather than as defaults on the shipped API — having a second definition of
# every default is precisely what let a verified value and an unverified one disagree (#140, #141).
#
# The defaults below therefore have no authority: they exist so a test can say "this video, this
# target width" in one line. Where a value is imputed rather than chosen, these call the same
# function the gateway calls (`get_window`), so there is still one rule per value.

"A `Tuning` for `file`, with the gateway's own imputations for anything not named."
function tuning(file; target_width = 25.0, window_size = missing, darker_target = true,
                fps = missing, video_fps = missing, initial_search_factor = 4.0, scale = 1.0,
                background_length = PawsomeTracker.DEFAULT_BACKGROUND_LENGTH,
                duration = missing)
    m = probe_stream(file)
    vfps = coalesce(video_fps, m.fps)
    f = coalesce(fps, vfps)
    ws = coalesce(window_size,
                  get_window(target_width, f, min(m.width, m.height),
                             coalesce(duration, m.nframes / m.fps)))
    return Tuning(target_width, ws, darker_target, f, vfps, initial_search_factor, scale,
                  background_length)
end

"""
    segments(files; start, stop, start_location)

The `Segment`s for `files` (one path or several). Each keyword is either one value for every
segment or a vector with one entry per file; `stop` defaults to each video's own duration and
`start_location` to `missing`, as a blank csv cell would.
"""
function segments(files; start = 0.0, stop = missing, start_location = missing)
    fs = files isa AbstractString ? [files] : collect(files)
    per(x, i) = x isa AbstractVector ? x[i] : x
    return Segment[Segment(f, per(start, i),
                           coalesce(per(stop, i), probe_stream(f).duration),
                           per(start_location, i))
                   for (i, f) in enumerate(fs)]
end

"""
    track1(files; rectification, diagnostic_file, <segment and tuning keywords>)

Track `files` as one run, building the `Segment`s and `Tuning` from keywords — the spelling
`track` itself used to have, kept for the tests that exercise the tracker directly. The `Tuning` is
built from the first file, as the gateway builds it from a run's first segment.
"""
function track1(files; rectification = nothing, diagnostic_file = nothing,
                start = 0.0, stop = missing, start_location = missing, kw...)
    segs = segments(files; start, stop, start_location)
    return track(segs, tuning(first(segs).file; duration = sum(s -> s.stop - s.start, segs), kw...),
                 rectification, diagnostic_file)
end

end
