# Print the residual behind every empirical tolerance in the suite, so the numbers recorded in the
# test comments can be checked on a platform other than the one they were measured on.
#
# NOT part of the test suite: `runtests.jl` does not include this, and it asserts nothing. It exists
# because every tolerance comment in `test/` states a value measured on one machine — one
# `FFMPEG_jll`, one `OpenCV_jll`, one `AprilTags_jll`, one Julia minor. Those numbers were verified
# bit-identical across processes and thread counts *there*, which says nothing about the macOS and
# Windows runners. A bound is only as good as the worst platform it has to hold on.
#
#     julia --project=test test/tolerance_residuals.jl
#
# or, on the CI matrix, through the ToleranceResiduals workflow (manual dispatch).
#
# Output is one TSV row per quantity — `RESIDUAL <site> <measured> <bound> <headroom>` — so runs
# from two platforms can be diffed directly.
#
# The checkerboard and projection helpers below are copied from the local helpers inside
# `test/Rectifications/test_calibration.jl`, which defines them within its own `@testset` and so
# cannot share them. If that fixture changes, this copy must change with it; everything else here
# comes from `test/fixtures.jl`, which is genuinely shared.

using Test
using Fromage: Fromage, Rectifications, PawsomeTracker
using StaticArrays, Rotations, LinearAlgebra, Printf

const R = Rectifications
const PT = PawsomeTracker

include(joinpath(@__DIR__, "fixtures.jl"))
using .Fixtures

row(site, measured, bound) =
    @printf("RESIDUAL\t%-46s\t%.10g\t%.10g\t%.4gx\n", site, measured, bound,
            measured == 0 ? Inf : bound / measured)

header() = println("""
    platform  : $(Sys.MACHINE)
    julia     : $(VERSION)
    threads   : $(Threads.nthreads())
    -- RESIDUAL <site> <measured> <bound> <headroom> ------------------------------------------""")

# ---------------------------------------------------------------------------------------------
# 1. Tracking accuracy. Depends on ffmpeg's render of the synthetic disc and on the DoG detector.
# ---------------------------------------------------------------------------------------------
function tracking_residuals(dir)
    base, base_exp = make_target_video(dir, "tr_base")
    light, light_exp = make_target_video(dir, "tr_light"; darker_target = false)
    seg, seg_exp = make_target_video(dir, "tr_seg"; nsegments = 3)
    f = joinpath(dir, only(base))

    _, ij = track1(f; start_location = (55, 50), target_width = 10)
    row("pawsometracker: explicit start_location", tracking_rmse(ij, base_exp), 0.5)

    _, ij = track1(f)
    row("pawsometracker: frame-centre default", tracking_rmse(ij, base_exp), 0.5)

    _, ij = track1(f; sample_fps = 12.5)
    row("pawsometracker: sample_fps 12.5 (skip 2)", tracking_rmse(ij, base_exp; skip = 2), 0.5)

    _, ij = track1(joinpath(dir, only(light)); darker_target = false)
    row("pawsometracker: lighter target", tracking_rmse(ij, light_exp), 0.5)

    _, ij = track1(joinpath.(dir, seg))
    row("pawsometracker: segmented (3 files)", tracking_rmse(ij, seg_exp), 1)

    # same arguments as the assertion this mirrors — start_location and target_width included,
    # without which the frame-centre search makes this a different measurement entirely
    _, ij = track1(f; start_location = (55, 50), target_width = 10, background_length = 0)
    row("pawsometracker: background_length = 0", tracking_rmse(ij, base_exp), 0.5)

    # background_length = 30: the rolling phase with subtraction on, which the 0 case above does
    # not exercise. Added after the first cross-platform run, which tightened every site it
    # covered and left this one at 1 for want of a number.
    _, ij = track1(f; start_location = (55, 50), target_width = 10, background_length = 30)
    row("pawsometracker: background_length = 30", tracking_rmse(ij, base_exp), 1)

    # the long-stationary target (30 s, an 8-25 s pause): the protect_target path, and the slowest
    # site here by far -- 750 frames against everything else's 50.
    paused, paused_exp = make_target_video(dir, "tol_pause"; duration = 30, pause = (8, 25))
    _, ij = track1(joinpath(dir, only(paused)); start_location = (55, 50), target_width = 10)
    row("pawsometracker: long-stationary (paused)", tracking_rmse(ij, paused_exp), 1)

    # determinism, which is the one property asserted without a tolerance
    _, a = track1(f; start_location = (55, 50), target_width = 10)
    _, b = track1(f; start_location = (55, 50), target_width = 10)
    println("DETERMINISM\ttracking a == b\t", a == b)
end

# ---------------------------------------------------------------------------------------------
# 2. Container duration. Depends on the mp4 timebase ffmpeg picks.
# ---------------------------------------------------------------------------------------------
function duration_residuals(dir)
    v = make_video(joinpath(dir, "dur_a.mp4"); duration = 1, size = (320, 240), rate = 25)
    m = probe_stream(joinpath(dir, "dur_a.mp4"))
    row("probing: duration 1 s @ 25 fps", abs(m.duration - 1.0), 0.2)

    make_video(joinpath(dir, "dur_b.mp4"); duration = 5, size = (640, 480), rate = 30)
    m = probe_stream(joinpath(dir, "dur_b.mp4"))
    row("test_reading: duration 5 s @ 30 fps", abs(m.duration - 5.0), 0.5)
end

# ---------------------------------------------------------------------------------------------
# 3. Camera calibration. Depends on OpenCV's corner detector and calibrateCamera.
#    Fixture copied from test/Rectifications/test_calibration.jl — keep in step.
# ---------------------------------------------------------------------------------------------
function checkerboard(inner::Tuple{Int,Int}; sq = 30, m = 40)
    nx, ny = inner
    bw, bh = (nx + 1) * sq, (ny + 1) * sq
    w, h = bw + 2m, bh + 2m
    img = fill(0xff, 1, h, w)
    for r in 1:h, c in 1:w
        (m < c ≤ m + bw && m < r ≤ m + bh) || continue
        isodd(((c - m - 1) ÷ sq) + ((r - m - 1) ÷ sq)) && (img[1, r, c] = 0x00)
    end
    img
end

function project(Xo, Rmat, t, fx, fy, cx, cy, k)
    Xc = Rmat * SVector{3,Float64}(Xo) + t
    x, y = Xc[1] / Xc[3], Xc[2] / Xc[3]
    r2 = x^2 + y^2
    rad = 1 + k[1] * r2 + k[2] * r2^2 + k[3] * r2^3
    SVector{2,Float32}(fx * x * rad + cx, fy * y * rad + cy)
end

function calibration_residuals()
    W, H = 640, 480
    fx, cx, cy = 1000.0, 320.0, 240.0
    n_corners = (7, 6)
    objpoints = R.XYZ.(Tuple.(CartesianIndices((0:(n_corners[1] - 1), 0:(n_corners[2] - 1), 0:0))))
    # the testset's own nine poses and its single-coefficient case — copied verbatim, because a
    # different pose spread gives a completely different fit (an invented one measured 26.4 px here
    # against the testset's 0.31, which is how this copy was caught being wrong)
    ktrue = (0.05, 0.0, 0.0)
    rvecs = [SVector(0.0, 0.0, 0.0), SVector(0.2, -0.1, 0.0), SVector(-0.15, 0.2, 0.05),
             SVector(0.1, 0.25, -0.1), SVector(-0.25, -0.1, 0.0), SVector(0.05, -0.2, 0.15),
             SVector(0.3, 0.0, 0.1), SVector(-0.1, -0.25, -0.05), SVector(0.18, 0.18, 0.0)]
    tvecs = [SVector(-3.0, -2.5, 16.0), SVector(-3.2, -2.0, 15.0), SVector(-2.5, -2.8, 17.0),
             SVector(-3.5, -2.5, 16.5), SVector(-2.8, -2.2, 15.5), SVector(-3.0, -3.0, 18.0),
             SVector(-3.3, -2.4, 16.0), SVector(-2.6, -2.6, 15.0), SVector(-3.1, -2.3, 17.5)]

    # the detector, on a noiseless integer-pitch board
    detected = R._detect_corners(checkerboard(n_corners), n_corners)
    if detected === missing
        println("SKIP\tcalibration: findChessboardCorners returned missing")
        return
    end
    row("test_calibration: checker_width_pixel", abs(R.checker_width_pixel(detected, n_corners) - 30), 0.5)

    views = map(zip(rvecs, tvecs)) do (rv, t)
        Rmat = SMatrix{3,3,Float64}(RotationVec(rv...))
        [project(Xo, Rmat, t, fx, fx, cx, cy, ktrue) for Xo in objpoints]
    end
    res = R.fit_model((W, H), objpoints, views, n_corners, 1, 1.0)
    row("test_calibration: |frow - fx|", abs(res.frow - fx), 1.0)
    row("test_calibration: |fcol - fy|", abs(res.fcol - fx), 1.0)
    row("test_calibration: |crow - cx|", abs(res.crow - cx), 1.0)
    row("test_calibration: |ccol - cy|", abs(res.ccol - cy), 1.0)
end

# ---------------------------------------------------------------------------------------------
# 4. AprilTag end-to-end. Depends on the AprilTags C detector as well as ffmpeg.
# ---------------------------------------------------------------------------------------------
function apriltag_residuals(dir)
    v = make_apriltag_video(dir, "tol_at"; nframes = 40, tw = 12, pose = drone_pose)
    ref = PT.ReferenceFrame(joinpath(dir, only(v.files)), 0.0, "tag36h11", 8.0, 4)
    if ref isa String
        println("SKIP\tapriltag: reference frame failed — ", ref)
        return
    end
    expected(k) = v.expected_ref(k)
    got = [PT.apply_h(ref.M, expected(k)) for k in 1:length(v.poses)]
    println("NOTE\tapriltag residuals need the full track; see test/fromage.jl for the e2e numbers")
    row("apriltag: identity registration (stationary)",
        maximum(norm(got[k] - got[1]) for k in eachindex(got)), 1e-6)
end

# ---------------------------------------------------------------------------------------------

function main()
    header()
    mktempdir() do dir
        try; tracking_residuals(dir) catch e; println("SKIP\ttracking: ", sprint(showerror, e)) end
        try; duration_residuals(dir) catch e; println("SKIP\tduration: ", sprint(showerror, e)) end
        try; calibration_residuals() catch e; println("SKIP\tcalibration: ", sprint(showerror, e)) end
    end
    println("-- end ------------------------------------------------------------------------------")
end

main()
