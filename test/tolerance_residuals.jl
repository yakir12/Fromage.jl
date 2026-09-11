# Print the residual behind every empirical tolerance in the suite, so the numbers recorded in the
# test comments can be checked on a platform other than the one they were measured on.
#
# NOT part of the test suite: `runtests.jl` does not include this, and it asserts nothing. It exists
# because every tolerance comment in `test/` states a value measured on one machine — one
# `FFMPEG_jll`, one `OpenCV_jll`, one `AprilTags_jll`, one Julia minor. Those numbers were verified
# bit-identical across processes and thread counts *there*, which says nothing about the macOS and
# Windows runners. A bound is only as good as the worst platform it has to hold on.
#
# What the first two dispatches found: linux, Intel macOS and Windows agree BIT-IDENTICALLY on every
# tracking and centre residual, and differ by ~2e-10 on the two focal lengths (OpenCV's iterative
# fit). Architecture is the axis that actually moves them -- an aarch64 (Apple Silicon) run came in
# ~1e-5 off on the tracking sites, presumably a different FFMPEG_jll render of the synthetic disc.
# Still four orders of magnitude inside the bounds, but it is why these say "measured", not
# "identical". What NO dispatch has measured is a jll VERSION bump: every runner resolves the same
# versions on the same day, so the headroom left in each bound is sized for that, not for this.
#
#     julia --project=test test/tolerance_residuals.jl
#
# or, on the CI matrix, through the ToleranceResiduals workflow (manual dispatch).
#
# Output is one TSV row per quantity — `RESIDUAL <site> <measured> <bound> <headroom>` — so runs
# from two platforms can be diffed directly.
#
# Two sets of helpers below are copied rather than shared, because each lives inside a `@testset`
# or a module that cannot be included without running its suite: the checkerboard and projection
# helpers, from `test/Rectifications/test_calibration.jl`, and `at_rectify`/`registration_trace`,
# from `test/apriltag_pipeline.jl`. Each copy carries a comment pointing at its original, and if
# the original changes the copy must change with it. Everything else here comes from
# `test/fixtures.jl`, which is genuinely shared.

using AprilTags: AprilTagDetector, freeDetector!, tag36h11
using Fromage: Rectifications, PawsomeTracker
using StaticArrays: SVector, SMatrix
using Rotations: RotationVec
using LinearAlgebra: norm
using Printf: @printf

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
    row("pawsometracker: background_length = 30", tracking_rmse(ij, base_exp), 0.5)

    # the long-stationary target (30 s, an 8-25 s pause): the protect_target path, and the slowest
    # site here by far -- 750 frames against everything else's 50.
    paused, paused_exp = make_target_video(dir, "tol_pause"; duration = 30, pause = (8, 25))
    _, ij = track1(joinpath(dir, only(paused)); start_location = (55, 50), target_width = 10)
    row("pawsometracker: long-stationary (paused)", tracking_rmse(ij, paused_exp), 0.5)

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
# 4. AprilTag end-to-end. Depends on the AprilTags C detector as well as ffmpeg — and
#    `AprilTags_jll` is the most platform-dependent dependency in the package (no aarch64 binaries
#    at all, see ToleranceResiduals.yml), which is why these rows are the ones this file most
#    exists for. Note that `test/fixtures.jl` does `using AprilTags` at load, so on a platform
#    where the detector cannot load this script produces NO rows at all, not three sections' worth
#    — which is why the CI matrix pins macos-15-intel over macos-latest.
#
#    Each row is the WORST residual over every site the bound has to hold on, not one flight's:
#    `REG_TOL` and `TRACK_TOL` bind every flight in test/apriltag_pipeline.jl, and the two
#    test/fromage.jl bounds bind both its AprilTag testsets. A bound is only as good as its
#    worst site, the same argument this file's header makes about platforms — and the 6-dof
#    flight alone measures 0.407 against a suite-wide worst of ~0.44.
#
#    Every bound below is DUPLICATED from the file that asserts it, because each lives inside a
#    module or a `@testset` that cannot be included without running the suite. They must move
#    together with their originals:
#      * AT_REG_TOL, AT_TRACK_TOL and the flight constants — test/apriltag_pipeline.jl
#      * AT_STRAIGHT_TOL, AT_DISP_RTOL — the two AprilTag testsets in test/fromage.jl
# ---------------------------------------------------------------------------------------------
const AT_NFRAMES = 40        # test/apriltag_pipeline.jl's NFRAMES
const AT_TARGET_WIDTH = 12   # its TARGET_WIDTH, which is also the fixture's default `tw`
const AT_FRAME = 480         # its FRAME — the fixture's frame is AT_FRAME x AT_FRAME
const AT_CENTRE = AT_FRAME ÷ 2
const AT_REG_TOL = 1.0       # its REG_TOL,   suite-wide worst case ~0.37 per its own comment
const AT_TRACK_TOL = 1.5     # its TRACK_TOL, suite-wide worst case ~0.44
const AT_STRAIGHT_TOL = 0.5  # test/fromage.jl: max deviation from the tracked chord, ground px
const AT_DISP_RTOL = 0.05    # test/fromage.jl: total displacement against the known ground path

# The six flights test/apriltag_pipeline.jl drives through `check_flight`, copied from its
# testsets — one drone degree of freedom at a time, then all six at once. Both its bounds hold
# over all of them, so all of them are measured.
const AT_FLIGHTS = [
    "stationary"  => k -> drone_pose(),
    "translation" => k -> drone_pose(dx = 55sin(2π*(k-1)/12), dy = 45cos(2π*(k-1)/12)),
    "scale"       => k -> drone_pose(zoom = 1 + 0.25sin(2π*(k-1)/15), cx = AT_CENTRE, cy = AT_CENTRE),
    "yaw"         => k -> drone_pose(yaw = deg2rad(25sin(2π*(k-1)/15)), cx = AT_CENTRE, cy = AT_CENTRE),
    "pitchroll"   => k -> drone_pose(pitch = deg2rad(14sin(2π*(k-1)/15)),
                                     roll = deg2rad(11cos(2π*(k-1)/15)),
                                     alt = 1000, cx = AT_CENTRE, cy = AT_CENTRE),
    "shear"       => k -> drone_pose(shear = 0.18sin(2π*(k-1)/15), cx = AT_CENTRE, cy = AT_CENTRE),
    "all6dof"     => k -> drone_pose(dx = 35sin(2π*(k-1)/13), dy = 28cos(2π*(k-1)/11),
                                     zoom = 1 + 0.18sin(2π*(k-1)/17),
                                     yaw = deg2rad(18sin(2π*(k-1)/19)),
                                     pitch = deg2rad(10sin(2π*(k-1)/23)),
                                     roll = deg2rad(8cos(2π*(k-1)/29)),
                                     alt = 1000, cx = AT_CENTRE, cy = AT_CENTRE),
]

# Copied from `rectify` and `registration_trace` in test/apriltag_pipeline.jl, which defines both
# inside its own module — including that file would run its whole testset. Keep in step with it.
# (`extrinsic` and the frame size are keywords here only because two sites below need other
# values; every caller that does not name them gets the original's.)
at_rectify(file; extrinsic = 0, width = AT_FRAME, height = AT_FRAME) =
    PT.ApriltagRectification(; aspect = 1.0, file, extrinsic, ntags = 4, family = "tag36h11",
                             tag_cell_width = Fixtures.TAG_CELL, center = missing, north = missing,
                             width, height)

# Detect and register every frame directly, with no tracker involved, and report where each frame
# says the disc is in REFERENCE coordinates. Frames are re-rendered in memory rather than decoded,
# so this isolates detection + registration from the video layer.
function registration_trace(v, ref)
    ground = apriltag_ground()
    det = PT.set_detector!(AprilTagDetector(tag36h11))
    ids = [0, 1, 2, 3]
    try
        map(1:AT_NFRAMES) do k
            img = render_pose(Fixtures.draw_disc(ground, v.groundpath[k]..., AT_TARGET_WIDTH),
                              v.poses[k], AT_FRAME, AT_FRAME)
            tc = PT.detect_tags(det, img, ids)
            isnothing(tc) && return nothing
            PT.apply_h(PT.register(ref, reduce(vcat, tc)), v.image_xy(k))
        end
    finally
        freeDetector!(det)
    end
end

"""
`track`'s reported coordinates against the pipeline's own declared maps (`ref.M`, then
`image2real`), which is the quantity `check_flight` asserts against TRACK_TOL. Both maps are
fixed properties of the reference space rather than of the track, so the prediction stays
independent of the thing it measures.
"""
function track_residual(name, file, rect, v; start_location = v.start_location)
    _, xy = track1(file; rectification = rect, start_location, target_width = AT_TARGET_WIDTH)
    any(ismissing, xy) && error("apriltag flight '$name': the track has gaps, so it has no residual")
    return maximum(norm(xy[k] - rect.image2real(PT.apply_h(rect.reference.M, v.expected_ref(k))))
                   for k in 1:AT_NFRAMES)
end

"One flight's registration and track residuals — the two maxima `check_flight` asserts."
function flight_residuals(dir, name, pose)
    v = make_apriltag_video(dir, "tol_$name"; nframes = AT_NFRAMES, tw = AT_TARGET_WIDTH, pose)
    file = joinpath(dir, v.file)
    rect = at_rectify(file)
    refpos = registration_trace(v, rect.reference)
    any(isnothing, refpos) &&
        error("apriltag flight '$name': a frame lost one of the four tags, so registration has no residual")
    return (registration = maximum(norm(refpos[k] - v.expected_ref(k)) for k in 1:AT_NFRAMES),
            track = track_residual(name, file, rect, v))
end

"""
The two end-to-end residuals test/fromage.jl asserts on a tracked path, both in ground pixels
(`tag_cell_width = TAG_CELL` makes one recovered metric unit exactly one of them — "cm" is only
the unit label the pipeline carries): the total displacement against the known straight ground
path, and the maximum deviation from the track's own chord. Measured between the first and last
frames that actually registered, as the assertions are.
"""
function e2e_residuals(groundpath, xy)
    pidx = findall(!ismissing, xy)
    present = [xy[i] for i in pidx]
    ground_disp = hypot((groundpath[pidx[end]] .- groundpath[pidx[1]])...)
    disp = hypot((present[end] - present[1])...)
    a, b = present[1], present[end]
    d = (b - a) ./ hypot((b - a)...)
    # `≈ ground_disp rtol = AT_DISP_RTOL` is `|disp - ground| <= rtol * max(|disp|, |ground|)`
    # (`isapprox`'s atol defaults to 0 when only rtol is given), so the residual the bound applies
    # to is the relative difference against that same max
    return (displacement = abs(disp - ground_disp) / max(disp, ground_disp),
            straightness = maximum(abs((p - a)[1] * d[2] - (p - a)[2] * d[1]) for p in present))
end

function apriltag_residuals(dir)
    # (a) the two pipeline bounds, over every site that asserts them
    fs = [flight_residuals(dir, name, pose) for (name, pose) in AT_FLIGHTS]

    # the non-square reference (400x480, so the viewport axis order is discriminating) and the
    # unseeded centre search: test/apriltag_pipeline.jl's last two testsets, which assert
    # TRACK_TOL but not REG_TOL
    wide = make_apriltag_video(dir, "tol_wideref"; H = 400, W = 480, nframes = AT_NFRAMES,
                               tw = AT_TARGET_WIDTH)
    wide_file = joinpath(dir, wide.file)
    wide_track = track_residual("wideref", wide_file,
                                at_rectify(wide_file; width = 480, height = 400), wide)

    seedless = make_apriltag_video(dir, "tol_noseed"; nframes = AT_NFRAMES, tw = AT_TARGET_WIDTH,
                                   pose = k -> drone_pose(dx = 30sin(2π*(k-1)/12),
                                                          dy = 24cos(2π*(k-1)/12)))
    seedless_file = joinpath(dir, seedless.file)
    # `start_location = missing` is the point: the tracker has to find the disc unaided
    seedless_track = track_residual("noseed", seedless_file, at_rectify(seedless_file), seedless;
                                    start_location = missing)

    row("apriltag_pipeline: registration (worst site)",
        maximum(f.registration for f in fs), AT_REG_TOL)
    row("apriltag_pipeline: track (worst site)",
        max(maximum(f.track for f in fs), wide_track, seedless_track), AT_TRACK_TOL)

    # (b) the two end-to-end bounds, over both flights that assert them: the 60-frame default
    # circular pan, and the 300-frame large pan whose first tag is occluded in eight frames
    plain = make_apriltag_video(dir, "tol_e2e")
    plain_file = joinpath(dir, plain.file)
    _, plain_xy = track1(plain_file; rectification = at_rectify(plain_file),
                         start_location = plain.start_location, target_width = AT_TARGET_WIDTH)
    e_plain = e2e_residuals(plain.groundpath, plain_xy)

    # extrinsic at t = 0.2 s (frame 6), as that testset uses: the frames around t = 0 have the
    # occluded tag, so frame 1 cannot build the reference
    occluded = make_apriltag_video(dir, "tol_bigpan"; nframes = 300, amp = 55,
                                   occlude = vcat(1:3, 260:264))
    occluded_file = joinpath(dir, occluded.file)
    _, occluded_xy = track1(occluded_file;
                            rectification = at_rectify(occluded_file; extrinsic = 0.2),
                            start_location = occluded.start_location,
                            target_width = AT_TARGET_WIDTH)
    e_occluded = e2e_residuals(occluded.groundpath, occluded_xy)

    row("fromage: e2e displacement vs ground (rel.)",
        max(e_plain.displacement, e_occluded.displacement), AT_DISP_RTOL)
    row("fromage: e2e straightness (dev. from chord)",
        max(e_plain.straightness, e_occluded.straightness), AT_STRAIGHT_TOL)
end

# ---------------------------------------------------------------------------------------------

# Run one section and say whether it succeeded. A throw is reported as `FAIL`, never `SKIP`: this
# script's whole value is the numbers, so a section that produced none is a broken script, and a
# `SKIP` line in output nobody reads is exactly how section 4 rotted unnoticed across a dozen
# releases (#220). `SKIP` stays for a genuine, expected unavailability — see `calibration_residuals`.
# Every section still runs whatever the others did, for the same reason the workflow matrix sets
# `fail-fast: false`: one failure must not hide the rest of the numbers.
#
# The broad `catch` is the `warn_on_failure` inversion (DECISIONS, "No bare catch"): nothing above
# a top-level script runner can act on the exception, and the backtrace goes out with it, because
# on a runner you cannot attach to the FAIL row is the whole diagnostic.
function section(f, name)
    try
        f()
        return true
    catch e
        e isa InterruptException && rethrow()       # #25: a broad catch here would eat Ctrl-C
        println("FAIL\t", name, "\t", sprint(showerror, e))
        showerror(stdout, e, catch_backtrace())
        println()
        return false
    end
end

function main()
    header()
    ok = mktempdir() do dir
        # a named vector, not `all(...)` over a generator: every section must run before anything
        # is reduced, and `all` over a lazy generator would stop at the first failure
        ran = [section(() -> tracking_residuals(dir), "tracking"),
               section(() -> duration_residuals(dir), "duration"),
               section(calibration_residuals, "calibration"),
               section(() -> apriltag_residuals(dir), "apriltag")]
        all(ran)
    end
    println("-- end ------------------------------------------------------------------------------")
    # non-zero, so a dispatched ToleranceResiduals job goes red rather than green-with-a-buried-line
    ok || exit(1)
end

main()
