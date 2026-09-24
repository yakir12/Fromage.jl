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
using Rotations: RotationVec
using Fromage.PawsomeTracker: PawsomeTracker, Segment, Tuning, get_window, track
using Fromage.VerifyRuns: probe_video

export make_video, make_checkerboard_video, make_corrupt_video, make_target_video,
    matlab_camera,
    make_squeezed_checkerboard_video, make_squeezed_disc_video, CHECKERBOARD_POSES,
    tracking_rmse, probe_stream, probe_frames, read_labels, label_differences,
    LABEL_CHANGED, ENCODING_NOISE,
    make_apriltag_video, drone_pose, apriltag_ground, render_pose, pose_apply,
    tuning, segments, track1

# ---------------------------------------------------------------------------
# Video artifacts.
# ---------------------------------------------------------------------------

function make_video(path; duration = 5, size = (640, 480), rate = 30)
    w, h = size
    FFMPEG.ffmpeg_exe(`-y -loglevel error -f lavfi -i testsrc=duration=$duration:size=$(w)x$(h):rate=$rate -pix_fmt yuv420p $path`)
    return path
end

function make_checkerboard_video(path, png; duration = 5)
    pad = "pad=ceil(iw/2)*2:ceil(ih/2)*2"   # libx264/yuv420p needs even dimensions
    FFMPEG.ffmpeg_exe(`-y -loglevel error -framerate 10 -loop 1 -i $png -t $duration -vf $pad -pix_fmt yuv420p $path`)
    return path
end

"""
    matlab_camera(; sar)

A fronto-parallel camera 100 mm above a plane, with display focal length 500 px and mild radial
distortion. Returns MATLAB calibration fields (1-based principal point), a `stored(X, Y)`
projection from millimetres to 0-based `(row, col)`, and display `center`/`north` anchoring the
plane's origin and negative Y direction. Y increases downward, so rectified truth is `(Y, X)`.
The column focal length is `500 / sar`; no package maps or coordinate conversions define truth.
This is an analytic camera, not area-resampled media: display x is stored column times `sar`.
"""
function matlab_camera(; sar)
    width, height = Int(640 / sar), 480
    f, Z, k1 = 500.0, 100.0, 0.1
    cx, cy = 287.0, 213.0                       # deliberately off-centre and unequal
    fields = Dict(
        "ImageSize" => [height, width] .* 1.0,
        "K" => [f / sar 0.0 cx / sar + 1; 0.0 f cy + 1; 0.0 0.0 1.0],
        "RotationVectors" => zeros(1, 3),
        "TranslationVectors" => [0.0 0.0 Z],
        "RadialDistortion" => [k1, 0.0]
    )
    stored = (X, Y) -> begin
        d = 1 + k1 * (X^2 + Y^2) / Z^2
        SVector(cy + f * Y / Z * d, (cx + f * X / Z * d) / sar)
    end
    return (; fields, stored, center = (cx, cy), north = (cx, cy - 100), width, height)
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
# stored-frame 0-based (row, col) of the disc center at sample i — the convention `track`
# returns (#276) — where sample i reads global frame `offset + (i − 1)·skip` (skip = video fps ÷
# requested fps).
#
# `container_sar = true` writes lossless FFV1 into Matroska instead of x264 into mp4. FFV1 has no
# field for the sample aspect ratio, so `sar` then lives in the container alone — where ffprobe
# reports it and VideoIO's codec context does not (#295). With x264 it is in the bitstream, where
# the two agree.
#
# `reported_sar` is the ratio the file is TAGGED with, when it should lie about the squeeze `sar`
# actually applied — the footage a declared `aspect` in runs.csv exists for. The ground truth
# follows `sar`, the squeeze, whatever the tag says.
function make_target_video(
        dir, name; width = 100, height = 100, sar = 1 // 1, fps = 25, duration = 2,
        target_width = 10, darker_target = true, row = 50, col = 55, nsegments = 1, pause = nothing,
        container_sar = false, reported_sar = sar
    )
    A = width / 2.5
    target_c, bkgd_c = darker_target ? (0, 255) : (255, 0)
    w2 = round(Int, width / sar)
    sarg = "$(numerator(reported_sar))/$(denominator(reported_sar))"
    # the frame index driving the trajectory: identity, or frozen at p1 for the pause's span
    p1, p2 = isnothing(pause) ? (0, 0) : round.(Int, pause .* fps)
    Nexpr = isnothing(pause) ? "N" : "if(lt(N,$p1),N,if(lt(N,$p2),$p1,N-($p2-$p1)))"
    freeze(N) = isnothing(pause) ? N : (N < p1 ? N : (N < p2 ? p1 : N - (p2 - p1)))
    vf = "geq=lum='if(lt(sqrt((X-$col+$A*sin(0.5*PI*($Nexpr)/$fps))^2+(Y-$row)^2),$(target_width / 2)),$target_c,$bkgd_c)':cb=128:cr=128,scale=$w2:$height,setsar=$sarg"
    # lossless either way (x264 at -qp 0, FFV1 always) — the analytic ground truth stays exact, with
    # no encoder noise around the disc
    codec, ext = container_sar ? (`-c:v ffv1`, "mkv") : (`-qp 0`, "mp4")
    src = `-y -loglevel error -f lavfi -i color=white:s=$(width)x$(height):d=$duration:r=$fps -vf $vf -pix_fmt yuv420p $codec`
    files = if nsegments == 1
        FFMPEG.ffmpeg_exe(`$src $(joinpath(dir, "$name.$ext"))`)
        ["$name.$ext"]
    else
        T = duration / nsegments
        kf = "expr:gte(t,n_forced*$T)"
        FFMPEG.ffmpeg_exe(`$src -force_key_frames $kf -f segment -segment_time $T $(joinpath(dir, name * "_%02d.$ext"))`)
        [string(name, "_", lpad(k, 2, '0'), ".$ext") for k in 0:(nsegments - 1)]
    end
    expected = (i; skip = 1, offset = 0) -> begin
        N = freeze(offset + (i - 1) * skip)
        (Float64(row), (col - A * sin(0.5π * N / fps)) / sar)
    end
    return files, expected
end

# A calibration clip's worth of checkerboard poses, `(rotation vector, translation)` in checker
# units, for a 7×6 board in front of a 640×480, f = 1000 camera: twelve varied poses for a well-posed
# calibration, then two more so the extrinsic frame is never the last (ffmpeg's input seek at end of
# stream is unreliable). Read at 10 fps, `t = (k − ½)/10` lands on 0-based frame `k` — ffmpeg's
# input seek returns the first frame at or after `t` — which is pose `k + 1`.
const CHECKERBOARD_POSES = [
    (SVector(0.0, 0.0, 0.0), SVector(-3.0, -2.5, 16.0)),
    (SVector(0.22, -0.12, 0.0), SVector(-3.2, -2.0, 15.0)),
    (SVector(-0.16, 0.2, 0.05), SVector(-2.5, -2.8, 17.0)),
    (SVector(0.12, 0.26, -0.1), SVector(-3.5, -2.5, 16.5)),
    (SVector(-0.26, -0.12, 0.0), SVector(-2.8, -2.2, 15.5)),
    (SVector(0.06, -0.22, 0.16), SVector(-3.0, -3.0, 18.0)),
    (SVector(0.3, 0.0, 0.1), SVector(-3.3, -2.4, 16.0)),
    (SVector(-0.12, -0.26, -0.05), SVector(-2.6, -2.6, 15.0)),
    (SVector(0.19, 0.19, 0.0), SVector(-3.1, -2.3, 17.5)),
    (SVector(-0.2, 0.1, 0.08), SVector(-2.9, -2.7, 16.2)),
    (SVector(0.1, -0.18, -0.06), SVector(-3.2, -2.6, 16.8)),
    (SVector(-0.08, 0.22, 0.0), SVector(-2.7, -2.4, 15.8)),
    (SVector(0.05, -0.05, 0.0), SVector(-3.0, -2.5, 16.0)),
    (SVector(-0.1, 0.1, 0.0), SVector(-3.0, -2.5, 16.0)),
]

"""
    make_squeezed_checkerboard_video(path, poses; sar, n_corners, f, width, height, fps = 10, supersample = 4)

A planar checkerboard filmed at each of `poses` (one frame per pose, a `(rotation vector, translation)`
pair in checker units) by a square-pixel pinhole camera, then squeezed physically into anamorphic
stored frames — the footage `from_checkerboard` meets when `sar ≠ 1`. Returns
`(; file, stored_width, stored)`.

The camera lives in display space: `width`×`height` square pixels, focal length `f` px, principal
point at the display centre, and OpenCV's pixel convention (0-based, pixel centres on integers). The
board's inner corners sit at the integer points of `0:n_corners[1]-1` × `0:n_corners[2]-1`, and it
extends one square beyond them on every side, on a white background.

The squeeze is an area integral, not a resample: stored column `j` covers the display span
`[j·sar − ½, (j + 1)·sar − ½]`, so a display `x` lands at stored column `(x + ½)/sar − ½`. That is
the area-exact mapping, not `Spaces.stored_x`'s `x / sar`: the two differ by a constant `½/sar − ½`
columns, which a fitted principal point absorbs but a `center` put through `to_stored` would not.
Every stored pixel averages `supersample`² samples across that footprint, which keeps the corners
sub-pixel. The encode is lossless and carries `setsar=sar`.

`stored(k, X, Y)` is the ground truth: board point `(X, Y)`, seen at pose `k`, in 0-based stored
`(row, col)`. It is computed here from the camera alone, never through the package's own maps or
`Spaces` conversions, so it can check them.
"""
function make_squeezed_checkerboard_video(
        path, poses; sar::Rational, n_corners, f, width, height, fps = 10, supersample = 4
    )
    stored_width = _squeezed_width(width, height, sar)
    Hs = [board_homography(f, width, height, rv, t) for (rv, t) in poses]
    nx, ny = n_corners
    black(X, Y) = -1 ≤ X ≤ nx && -1 ≤ Y ≤ ny && isodd(floor(Int, X) + floor(Int, Y))
    _render_squeezed(path, Hs, (_, X, Y) -> black(X, Y); sar, stored_width, height, fps, supersample)
    stored(k, X, Y) = _board_to_stored(Hs[k], X, Y, sar)
    return (; file = path, stored_width, stored)
end

"""
    make_squeezed_disc_video(path, pose; board_path, nframes, diameter, sar, f, width, height, fps = 10, supersample = 4)

A dark disc of `diameter` checker units sliding over a white plane at the board pose `pose`, filmed
by the same camera, and squeezed the same way, as [`make_squeezed_checkerboard_video`](@ref). Its
centre is at board point `board_path(k)` in frame `k` (1-based). Pass the calibration clip's
extrinsic pose, and a rectification built from that clip maps this clip's pixels onto the disc's
own board coordinates. Returns `(; file, stored_width, stored, board)`.

`stored(X, Y)` is board point `(X, Y)` in 0-based stored `(row, col)`. `board(x, y)` goes the other
way, from 0-based display `(x, y)` to the board point seen there. It is what a `center` read off
the screen names. Both come from the camera alone, never from the package's maps or `Spaces`, so
they can check them (#276).
"""
function make_squeezed_disc_video(
        path, pose; board_path, nframes, diameter, sar::Rational, f, width, height, fps = 10, supersample = 4
    )
    stored_width = _squeezed_width(width, height, sar)
    H = board_homography(f, width, height, pose...)
    dark(k, X, Y) = hypot(X - board_path(k)[1], Y - board_path(k)[2]) ≤ diameter / 2
    _render_squeezed(path, fill(H, nframes), dark; sar, stored_width, height, fps, supersample)
    stored(X, Y) = _board_to_stored(H, X, Y, sar)
    board(x, y) = (w = inv(H) * SVector(Float64(x), Float64(y), 1.0); (w[1] / w[3], w[2] / w[3]))
    return (; file = path, stored_width, stored, board)
end

# Board (X, Y) → 0-based display (x, y), for the square-pixel `width`×`height` camera of focal length
# `f` with its principal point at the display centre: the plane's homography K·[r1 r2 t].
function board_homography(f, width, height, rv, t)
    K = SMatrix{3, 3, Float64}(f, 0, 0, 0, f, 0, (width - 1) / 2, (height - 1) / 2, 1)
    Rm = SMatrix{3, 3, Float64}(RotationVec(rv...))
    return K * hcat(Rm[:, 1], Rm[:, 2], SVector{3, Float64}(t))
end

function _squeezed_width(width, height, sar)
    isinteger(width / sar) && iseven(Int(width / sar)) && iseven(height) ||
        throw(ArgumentError("a $(width)×$(height) display at sar $sar has no even stored frame size"))
    return Int(width / sar)
end

# The board point seen at pose `H`, in 0-based stored (row, col): the area-exact squeeze.
function _board_to_stored(H, X, Y, sar)
    v = H * SVector(Float64(X), Float64(Y), 1.0)
    x, y = v[1] / v[3], v[2] / v[3]
    return (y, (x + 0.5) / Float64(sar) - 0.5)
end

# Render frame `k` through `Hs[k]`, a pixel dark where `dark(k, X, Y)` holds at the board point it
# sees, squeezing into stored columns by area, and encode it losslessly with `setsar`.
function _render_squeezed(path, Hs, dark; sar, stored_width, height, fps, supersample)
    offsets = ((1:supersample) .- 0.5) ./ supersample .- 0.5
    sar_f = Float64(sar)
    raw = path * ".gray"
    open(raw, "w") do io
        frame = Matrix{UInt8}(undef, stored_width, height)     # column-major = ffmpeg's row-major
        for (k, H) in enumerate(Hs)
            Hinv = inv(H)
            for r in 0:(height - 1), j in 0:(stored_width - 1)
                n = 0
                for dr in offsets, dj in offsets
                    x = (j + dj + 0.5) * sar_f - 0.5
                    w = Hinv * SVector(x, r + dr, 1.0)
                    n += dark(k, w[1] / w[3], w[2] / w[3])
                end
                frame[j + 1, r + 1] = round(UInt8, 255 * (1 - n / supersample^2))
            end
            write(io, frame)
        end
    end
    sarg = "$(numerator(sar))/$(denominator(sar))"
    FFMPEG.ffmpeg_exe(`-y -loglevel error -f rawvideo -pix_fmt gray -s $(stored_width)x$(height) -r $fps -i $raw -vf setsar=$sarg -c:v libx264 -qp 0 -pix_fmt yuv420p $path`)
    rm(raw)
    return path
end

"RMSE (in stored-frame pixels) between tracked coordinates and the ground-truth closure."
function tracking_rmse(ij, expected; skip = 1, offset = 0)
    return sqrt(mean([sum(abs2, Tuple(rc) .- expected(i; skip, offset)) for (i, rc) in enumerate(ij)]))
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
# 10 * TAG_CELL px square. TAG_CELL is also what the rectifications.csv row declares as `tag_cell_width`, which
# makes one recovered metric unit exactly one ground pixel and the tracked cm path therefore
# directly comparable to the intended ground path.
const TAG_CELL = 8
const TAG_BLOCKS = [(150, 150), (150, 370), (370, 150), (370, 370)]   # (row, col) of each block

"""
The static ground plane: white — or `ground_texture` when `textured` — with tag36h11 ids 0:3 at
`tag_blocks` (ground row, col). Each tag block carries its own white quiet zone either way.
"""
function apriltag_ground(GH = 600, GW = 600; tag_blocks = TAG_BLOCKS, textured = false)
    upscale(t) = UInt8.(kron(Int.(t), ones(Int, TAG_CELL, TAG_CELL)))
    tagu8(id) = UInt8.(255 .* (Float64.(getAprilTagImage(id, tag36h11)) .> 0.5))
    ground = textured ? ground_texture(GH, GW) : fill(0xff, GH, GW)
    for ((r, c), id) in zip(tag_blocks, 0:3)
        ground[(r + 1):(r + 10TAG_CELL), (c + 1):(c + 10TAG_CELL)] .= upscale(tagu8(id))
    end
    return ground
end

# A ground with structure at the target's own scale, for the tests a plain white ground cannot see:
# a background pixel pasted from the wrong ground position is invisible on white, and a dark ghost
# blob on this (#341). Three plane waves on mutually incommensurate periods (in ground px), so no
# shift the tests make maps the texture onto itself; closed-form, so it is the same on every
# platform and Julia version, unlike a seeded RNG stream. Gray levels span 145:255.
ground_texture(GH, GW) = [
    round(
        UInt8, 200 + 55 / 3 * (
            sin(2π * (c / 17.3 + r / 41.9)) + sin(2π * (c / 29.7 - r / 13.1) + 1.3) +
                sin(2π * (r / 21.1 + c / 53.3) + 2.9)
        )
    ) for r in 1:GH, c in 1:GW
]

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
function drone_pose(;
        dx = 0.0, dy = 0.0, zoom = 1.0, yaw = 0.0, pitch = 0.0, roll = 0.0,
        shear = 0.0, alt = 1000.0, cx = 0.0, cy = 0.0
    )
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
        out[i, j] = round(
            UInt8, (1 - fy) * ((1 - fx) * ground[y0, x0] + fx * ground[y0, x0 + 1]) +
                fy * ((1 - fx) * ground[y0 + 1, x0] + fx * ground[y0 + 1, x0 + 1])
        )
    end
    return out
end

# The disc, burned into a copy of the ground plane at ground position `(r0, c0)`, at gray `value`.
function draw_disc(ground, r0, c0, tw; value = 0x00)
    g = copy(ground)
    rad = tw / 2
    for i in floor(Int, r0 - rad):ceil(Int, r0 + rad), j in floor(Int, c0 - rad):ceil(Int, c0 + rad)
        (i - r0)^2 + (j - c0)^2 <= rad^2 && (g[i, j] = value)
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

`tag_blocks` places the tags in ground-canvas `(row, col)` pixels. The disc moves linearly from
`ground_start` to `ground_stop`, also in ground-canvas pixels (1-based array indices). `pause`, a
range of frames after the first, holds it still through those frames, and it still ends at
`ground_stop`. `disc_gray` is its gray level, and `textured` swaps the white ground for
`ground_texture`. `flash`, a range of frames, paints a white square `flash_half` px either side
of the disc's centre under it through those frames: a bright object (an experimenter's arm)
passing over a target that stays visible. All off by default, so existing flights render
bit-identically.

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
function make_apriltag_video(
        dir, name; H = 480, W = 480, GH = 600, GW = 600,
        nframes = 60, fps = 25, tw = 12, amp = 40, pose = nothing,
        occlude = Int[], tag_blocks = TAG_BLOCKS,
        ground_start = (260.0, 260.0), ground_stop = (300.0, 320.0),
        textured = false, disc_gray = 0x00, pause = 1:0, flash = 1:0, flash_half = 0
    )
    ox0, oy0 = (GW - W) ÷ 2, (GH - H) ÷ 2                   # the fixed crop: ground -> frame
    turn(k) = 2π * (k - 1) / nframes
    # The default flight is the legacy circular pan, expressed as a pose. Its offsets are rounded
    # exactly as the crop used to round them (`round(Int, ox0 + amp*cos)`, not `ox0 + round(...)`
    # — those differ on a tie), so the render stays an exact pixel copy of that crop.
    poses = if isnothing(pose)
        [
            drone_pose(
                dx = -round(Int, ox0 + amp * cos(turn(k))),
                dy = -round(Int, oy0 + amp * sin(turn(k)))
            ) for k in 1:nframes
        ]
    else
        base = drone_pose(dx = -ox0, dy = -oy0)
        [pose(k) * base for k in 1:nframes]                 # `pose` moves the drone about the frame
    end

    # the disc's steps along its path by frame `k`: each frame in `pause` repeats the one before it
    isempty(pause) || first(pause) > 1 || throw(ArgumentError("a pause needs a frame before it to hold"))
    moving = nframes - length(pause)
    steps(k) = k - 1 - clamp(k - first(pause) + 1, 0, length(pause))
    gr(k) = ground_start[1] + (ground_stop[1] - ground_start[1]) * steps(k) / (moving - 1)
    gc(k) = ground_start[2] + (ground_stop[2] - ground_start[2]) * steps(k) / (moving - 1)
    ground_xy(k) = SVector(gc(k), gr(k))                    # the same point as (x, y)

    ground = apriltag_ground(GH, GW; tag_blocks, textured)
    occluded = copy(ground)
    r, c = first(tag_blocks)
    occluded[(r + 1):(r + 10TAG_CELL), (c + 1):(c + 10TAG_CELL)] .= 0xff    # the first tag painted out
    raw = joinpath(dir, "$name.raw")
    open(raw, "w") do io
        for k in 1:nframes
            g = k in occlude ? occluded : ground
            if k in flash
                g = copy(g)
                rows, cols = (round(Int, x - flash_half):round(Int, x + flash_half) for x in (gr(k), gc(k)))
                g[rows, cols] .= 0xff
            end
            g = draw_disc(g, gr(k), gc(k), tw; value = disc_gray)
            write(io, vec(permutedims(render_pose(g, poses[k], H, W))))   # row-major for ffmpeg
        end
    end
    FFMPEG.ffmpeg_exe(`-y -loglevel error -f rawvideo -pix_fmt gray -s $(W)x$(H) -r $fps -i $raw -pix_fmt yuv420p -qp 0 $(joinpath(dir, "$name.mp4"))`)
    rm(raw)

    # `render_pose` samples at Julia indices, so the poses map 1-based pixels. Take one off to reach
    # the 0-based pixels `track`, the tag corners and `start_location` all use (#276).
    expected_ref = k -> pose_apply(poses[1], ground_xy(k)) .- 1
    image_xy = k -> pose_apply(poses[k], ground_xy(k)) .- 1
    return (;
        file = "$name.mp4",
        groundpath = [(gr(k), gc(k)) for k in 1:nframes],
        start_location = Tuple(round.(Int, expected_ref(1))),
        nframes, expected_ref, poses, image_xy, ground_xy,
    )
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
    return (;
        width = parse(Int, fields["width"]), height = parse(Int, fields["height"]),
        nframes = parse(Int, fields["nb_read_frames"]), fps = num / den,
        duration = something(tryparse(Float64, get(fields, "duration", "")), NaN),
    )
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

"""
    read_labels(file, candidates, font)

The label each frame of the diagnostic `file` carries, as the `(segment number, file time)` pair
from `candidates` that it matches. `font` is the pixel size the diagnostic drew at, and the `run_id`
is the file's name, as `Diagnostic` takes it.

A decoded frame is lossy, so no candidate reproduces it exactly: the label a frame carries is the
candidate whose rendering over it changes it least. That is only a claim about the candidates
offered, so offer the wrong answers a bug would produce — the run time, the other segment's number.
"""
function read_labels(file, candidates, font)
    run_id = first(splitext(basename(file)))
    face = PawsomeTracker.FTFont(String(PawsomeTracker.FONT))
    mismatch(frame, (k, t)) = sum(
        abs(Float32(a) - Float32(b))
            for (a, b) in zip(PawsomeTracker.stamp!(copy(frame), face, font, run_id, k, t), frame)
    )
    return [argmin(c -> mismatch(frame, c), candidates) for frame in decode_frames(file)]
end

"Every frame of `file`, decoded to gray, in order."
function decode_frames(file)
    vid = PawsomeTracker.open_gray_video(file)
    try
        # `eof` is asked before each read, as a `while !eof` loop would, but the vector comes out typed
        return [collect(read(vid)) for _ in Iterators.takewhile(_ -> !eof(vid), Iterators.repeated(nothing))]
    finally
        close(vid)
    end
end

"""
    label_region(run_ids, font, frame)

The pixels a diagnostic's label can cover, as a `BitMatrix` the size of `frame`, for a run named any of
`run_ids` and drawn at pixel size `font`. Taken from `stamp!` itself rather than from its geometry
restated: every pixel it changes on a black canvas or a white one (so the glyphs and the box behind
them both count), over a bounding box grown by one 16-pixel H.264 macroblock on every side, because
a lossy encode smears a change into the blocks around it.
"""
function label_region(run_ids, font, frame)
    face = PawsomeTracker.FTFont(String(PawsomeTracker.FONT))
    changed = falses(size(frame))
    for run_id in run_ids, v in (zero(eltype(frame)), oneunit(eltype(frame)))
        canvas = fill(v, size(frame))
        # the second line's widest plausible text; the pad absorbs any glyph wider than an 8
        segment, t = 88, 3600 * 88 + 88.888
        changed .|= PawsomeTracker.stamp!(copy(canvas), face, font, run_id, segment, t) .!= canvas
    end
    drawn = findall(changed)
    isempty(drawn) && throw(ArgumentError("`stamp!` drew nothing at font $font on a $(size(frame)) canvas"))
    (r0, r1), (c0, c1) = extrema(i -> i[1], drawn), extrema(i -> i[2], drawn)
    pad = 16
    region = falses(size(frame))
    region[max(1, r0 - pad):min(end, r1 + pad), max(1, c0 - pad):min(end, c1 + pad)] .= true
    return region
end

# The two sides of `label_differences`, measured on the AprilTag fixture: a changed label scores
# 0.040 in its region, and the same label re-encoded at another preset or at crf 28 at most 0.0006
# (0.00003 outside it). A frame whose label changed must score above the first, and content that
# did not change must score below the second, in whichever region.
const LABEL_CHANGED = 0.01
const ENCODING_NOISE = 0.002

"""
    label_differences(a, b, run_ids, font; frames = :)

How far the diagnostics `a` and `b` differ, decoded, inside the label region of `run_ids` (see
`label_region`) and outside it, as `(label, elsewhere)`: one score per compared frame for each,
the fraction of that region's pixels whose gray value differs by more than a quarter of the range.
A glyph against its background box differs by far more than that, and encoding noise at the
diagnostic's crf by far less, so a region that carries different text scores high and the same
content encoded twice scores close to zero — see `LABEL_CHANGED` and `ENCODING_NOISE`.
"""
function label_differences(a, b, run_ids, font; frames = :)
    fa, fb = decode_frames(a)[frames], decode_frames(b)[frames]
    length(fa) == length(fb) && !isempty(fa) ||
        throw(ArgumentError("compared $(length(fa)) frames of $a with $(length(fb)) of $b"))
    region = label_region(run_ids, font, first(fa))
    score(mask) = [count(abs.(Float32.(x[mask]) .- Float32.(y[mask])) .> 0.25) / count(mask) for (x, y) in zip(fa, fb)]
    return score(region), score(.!region)
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
function tuning(
        file; target_width = 25.0, window_size = missing, darker_target = true,
        native_fps = missing, sample_fps = missing, initial_search_factor = 4.0, downscale = 1.0,
        background_length = PawsomeTracker.DEFAULT_BACKGROUND_LENGTH, aspect = missing,
        duration = missing
    )
    m = probe_stream(file)
    # the gateway's own cascade: the probe fills a blank `native_fps`, and `native_fps` — declared
    # or probed — fills a blank `sample_fps`
    nfps = coalesce(native_fps, m.fps)
    sfps = coalesce(sample_fps, nfps)
    ws = coalesce(
        window_size,
        get_window(
            target_width, sfps, min(m.width, m.height),
            coalesce(duration, m.nframes / m.fps)
        )
    )
    # the ratio the gateway's own probe reads — ffprobe's, not VideoIO's (#295)
    asp = coalesce(aspect, probe_video(file).sar)
    return Tuning(
        target_width, ws, darker_target, sfps, nfps, initial_search_factor, downscale,
        background_length, asp
    )
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
    return Segment[
        Segment(
            f, per(start, i),
            coalesce(per(stop, i), probe_stream(f).duration),
            per(start_location, i)
        )
            for (i, f) in enumerate(fs)
    ]
end

"""
    track1(files; rectification, diagnostic_file, <segment and tuning keywords>)

Track `files` as one run, building the `Segment`s and `Tuning` from keywords — the spelling
`track` itself used to have, kept for the tests that exercise the tracker directly. The `Tuning` is
built from the first file, as the gateway builds it from a run's first segment.
"""
function track1(
        files; rectification = nothing, diagnostic_file = nothing,
        start = 0.0, stop = missing, start_location = missing, kw...
    )
    segs = segments(files; start, stop, start_location)
    return track(
        segs, tuning(first(segs).file; duration = sum(s -> s.stop - s.start, segs), kw...),
        rectification, diagnostic_file
    )
end

end
