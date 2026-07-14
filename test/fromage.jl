# End-to-end: a synthetic data folder (one checkerboard calibration video + one trackable run
# video + the two CSVs) driven through `main`, which validates both files, builds the
# rectification, tracks the run with the rectification attached, and writes the concatenated
# diagnostic video into results_dir under the current directory.
module FromageTests

using Test
using Fromage
using DataFrames: DataFrame, nrow
using StaticArrays: SVector
using MAT: matwrite
using AprilTags: getAprilTagImage, tag36h11
using FFMPEG: ffmpeg_exe

include("common.jl")

# A synthetic "drone" video for the AprilTag pipeline: four tag36h11 tags fixed on a ground canvas, a
# dark disc target moving along a known straight ground path, and a per-frame pan (a cropping window
# sliding over the larger ground canvas) that stands in for drone motion — registration must cancel
# it. Encoded losslessly (-qp 0) so the tags stay crisp for detection. `checker_size = cell = 8` (tag
# cells are 8 px on the ground) makes the recovered metric unit equal one ground pixel, so the tracked
# cm path is directly comparable to `groundpath`. `amp` is the pan amplitude (px; at most 59 to stay
# inside the canvas margins) and frames listed in `occlude` get the first tag painted over (a lost
# tag ⇒ that frame cannot register). Returns (basename, groundpath::Vector{(row, col)},
# start_location::(x, y) of the disc in frame 1, nframes).
function make_apriltag_video(dir, name; H = 480, W = 480, GH = 600, GW = 600, nframes = 60, fps = 25, tw = 12,
                             amp = 40, occlude = Int[])
    cell = 8                                            # ground px per tag cell ⇒ 8-cell black square = 64 px
    upscale(t) = UInt8.(kron(Int.(t), ones(Int, cell, cell)))
    tagu8(id) = UInt8.(255 .* (Float64.(getAprilTagImage(id, tag36h11)) .> 0.5))
    ground = fill(0xff, GH, GW)                         # white background with quiet zones around each tag
    for (p, id) in zip([(150, 150), (150, 370), (370, 150), (370, 370)], 0:3)
        r, c = p; ground[r+1:r+80, c+1:c+80] .= upscale(tagu8(id))
    end
    rad = tw ÷ 2
    gr(k) = 260.0 + 40 * (k - 1) / (nframes - 1)        # disc ground path (row, col): a straight line
    gc(k) = 260.0 + 60 * (k - 1) / (nframes - 1)
    oy(k) = round(Int, 60 + amp * sin(2π * (k - 1) / nframes))   # drone pan (crop offset), within the margins
    ox(k) = round(Int, 60 + amp * cos(2π * (k - 1) / nframes))
    raw = joinpath(dir, "$name.raw")
    open(raw, "w") do io
        for k in 1:nframes
            g = copy(ground); r0 = gr(k); c0 = gc(k)
            for i in floor(Int, r0 - rad):ceil(Int, r0 + rad), j in floor(Int, c0 - rad):ceil(Int, c0 + rad)
                (i - r0)^2 + (j - c0)^2 ≤ rad^2 && (g[i, j] = 0x00)
            end
            k in occlude && (g[151:230, 151:230] .= 0xff)               # paint over the first tag
            write(io, vec(permutedims(g[oy(k)+1:oy(k)+H, ox(k)+1:ox(k)+W])))   # row-major gray for ffmpeg
        end
    end
    ffmpeg_exe(`-y -loglevel error -f rawvideo -pix_fmt gray -s $(W)x$(H) -r $fps -i $raw -pix_fmt yuv420p -qp 0 $(joinpath(dir, "$name.mp4"))`)
    groundpath = [(gr(k), gc(k)) for k in 1:nframes]
    start_location = (round(Int, gc(1) - ox(1) + 1), round(Int, gr(1) - oy(1) + 1))   # disc (x, y) in frame 1
    return "$name.mp4", groundpath, start_location, nframes
end

@testset "Fromage end-to-end (main)" begin
    dir = mktempdir()

    # calibration video: the static 500×376 checkerboard used by the VerifyRectifications suite;
    # run video: the shared known-trajectory disc (defaults: 100×100, 2 s at 25 fps, start (55, 50))
    png = joinpath(@__DIR__, "VerifyRectifications", "fixtures", "checkerboard.png")
    make_checkerboard_video(joinpath(dir, "board.mp4"), png)
    target, expected = make_target_video(dir, "target")

    # n_corners and target_width are deliberately NOT in the CSVs: they arrive via main's global
    # defaults (the hardcoded n_corners (7, 10) would fail detection on the 5×8 board, so a clean
    # run proves the kwargs propagated into both gateways)
    open(joinpath(dir, "calibs.csv"), "w") do io
        println(io, "calibration_id,file,type,extrinsic,start,stop,checker_size")
        println(io, "c1,board.mp4,video,1,0,4,4")
    end
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "calibration_id,file,start_location")
        println(io, "c1,$(only(target)),\"(55, 50)\"")
    end

    # main writes results_dir/diagnostic.mp4 relative to the current directory
    outdir = mktempdir()
    runs = cd(() -> main(dir; rectification_defaults = (n_corners = (5, 8),),
                              tracking_defaults = (target_width = 10,)), outdir)

    @test runs isa DataFrame
    @test nrow(runs) == 1
    t, xy = only(runs.run)                          # track returns (timestamps, REAL-WORLD coords)
    @test length(xy) == 50                          # the full 2 s at 25 fps
    # ground truth is the analytic pixel path pushed through the same rectification
    real_expected(i; kw...) = Tuple(only(runs.rectification).image2real(SVector(expected(i; kw...)...)))
    @test tracking_rmse(xy, real_expected) < 0.3    # tracked vs ground truth, in real-world units
    @test only(runs.rectification).ratio > 0        # the joined rectification is a real one
    diag = joinpath(outdir, "results_dir", "diagnostic.mp4")
    @test isfile(diag)
    @test filesize(diag) > 0
    # the diagnostic contract: fixed square canvas, 2× real time — 50 tracked frames at 25 fps
    # write every 2nd frame, declared at 25 fps ⇒ 25 frames spanning 1 s of playback
    s = probe_stream(diag)
    @test (s.width, s.height) == (540, 540)
    @test s.nframes == 25
    @test s.fps ≈ 25
    @test s.duration ≈ 1.0 atol = 0.2
    # one track csv per run: time and the REAL-WORLD x/y (track already applied the rectification),
    # one row per detected coordinate (run_id imputed to "1")
    lines = readlines(joinpath(outdir, "results_dir", "1.csv"))
    @test length(lines) == 51                       # header + 50 coordinates
    @test lines[1] == "time,x,y"
    t0, x0, y0 = parse.(Float64, split(lines[2], ','))
    @test t0 == 0.0
    # the analytic ground-truth pixel, pushed through the same rectification (which returns
    # (y-direction, x-direction), mirroring its (row, col) input)
    gy, gx = only(runs.rectification).image2real(SVector(expected(1)...))
    @test x0 ≈ gx atol = 0.2
    @test y0 ≈ gy atol = 0.2
end

@testset "only_rectify / only_track (partial pipeline)" begin
    # The two iterate-on-your-csv helpers, each over the cheapest possible inputs: an only_scale
    # calibration (no checkerboard detection) and the shared known-trajectory disc video.
    dir = mktempdir()
    make_video(joinpath(dir, "cal.mp4"); size = (320, 240), duration = 2)
    target, expected = make_target_video(dir, "solo")
    open(joinpath(dir, "calibs.csv"), "w") do io
        println(io, "calibration_id,type,file,extrinsic,scale")
        println(io, "c1,only_scale,cal.mp4,1,2")
    end
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "calibration_id,file,start_location")
        println(io, "c1,$(only(target)),\"(55, 50)\"")
    end
    outdir = mktempdir()

    calibs = cd(() -> Fromage.only_rectify(dir), outdir)
    @test length(calibs) == 1
    rect = only(calibs)
    @test rect.ratio == 2                           # the csv's scale
    @test (rect.width, rect.height) == (320, 240)
    p = SVector(7.0, 11.0)
    @test rect.real2image(rect.image2real(p)) ≈ p   # the two maps are inverses

    # no rectification involved: raw pixel coordinates, one raw-view diagnostic per run (numbered)
    runs = cd(() -> Fromage.only_track(dir; tracking_defaults = (target_width = 10,)), outdir)
    @test length(runs) == 1
    _, ij = only(runs)
    @test length(ij) == 50                          # the full 2 s at 25 fps
    @test tracking_rmse(ij, expected) < 1
    diag = joinpath(outdir, "results_dir", "1.mp4")
    @test isfile(diag)
    @test filesize(diag) > 0
end

@testset "Fromage end-to-end: AprilTag drone tracking" begin
    # The whole AprilTag path through `main`: a `type = apriltag` calibs row builds the shared
    # reference from the extrinsic frame; the run registers each frame to it (cancelling the drone
    # pan) and is reported in metric ground coordinates. Exercises detection, reference building,
    # motion cancellation, the metric scale (checker_size = cell size), the centre/north gauge, and
    # the csv/diagnostic outputs — the pure geometry is unit-tested separately in test/apriltag.jl.
    dir = mktempdir()
    vid, groundpath, sl, nframes = make_apriltag_video(dir, "drone")
    open(joinpath(dir, "calibs.csv"), "w") do io
        println(io, "calibration_id,type,file,extrinsic,apriltags,family,checker_size")
        println(io, "drone,apriltag,$vid,0,4,tag36h11,8")
    end
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "run_id,calibration_id,file,start_location,target_width")
        println(io, "beetle,drone,$vid,\"$sl\",12")
    end
    outdir = mktempdir()
    runs = cd(() -> main(dir), outdir)

    @test nrow(runs) == 1
    rect = only(runs.rectification)
    @test rect isa Fromage.PawsomeTracker.ApriltagRectification   # the joined rectification is the apriltag kind
    @test rect.ratio > 0
    ts, xy = only(runs.run)
    @test length(xy) == nframes
    @test !any(ismissing, xy)                          # every frame held all four tags (no gaps)
    # checker_size = 8 ⇒ one metric unit = one ground pixel, so the tracked path is directly
    # comparable to the known straight ground path: the same total displacement (drone pan cancelled),
    # and straight (small deviation from its own chord).
    present = collect(skipmissing(xy))
    ground_disp = hypot((groundpath[end] .- groundpath[1])...)
    @test hypot((present[end] - present[1])...) ≈ ground_disp rtol = 0.05
    a, b = present[1], present[end]; d = (b - a) ./ hypot((b - a)...)
    @test maximum(abs((p - a)[1] * d[2] - (p - a)[2] * d[1]) for p in present) < 3   # within 3 cm of the line
    # outputs: one track csv (real-world x/y) and the shared diagnostic video
    lines = readlines(joinpath(outdir, "results_dir", "beetle.csv"))
    @test length(lines) == nframes + 1 && lines[1] == "time,x,y"
    diag = joinpath(outdir, "results_dir", "diagnostic.mp4")
    @test isfile(diag) && filesize(diag) > 0
end

@testset "AprilTag: registered stack survives a large pan, the rolling phase, and tag loss" begin
    # A harder synthetic flight than the e2e above, aimed at the registered background stack: a
    # large pan amplitude (the crop window sweeps nearly the whole canvas margin), more frames than
    # the background window (so the rolling phase actually runs — the e2e above fits entirely in
    # the prefill), and the first tag occluded both BEFORE the first full tag set (exercising the
    # backfilled pre-seed registrations) and inside the rolling phase (the borrowed ones). Driven
    # through `track` directly (no CSVs) with a start_location, which must cross the seed frame's
    # registration to land on the (reference-space) stack.
    dir = mktempdir()
    occluded = vcat(1:3, 260:264)
    vid, groundpath, sl, nframes = make_apriltag_video(dir, "bigpan"; nframes = 300, amp = 55, occlude = occluded)
    file = joinpath(dir, vid)
    # extrinsic at t = 0.2 s (frame 6): the frames around t = 0 have the occluded tag
    rect = Fromage.PawsomeTracker.ApriltagRectification(file, 0.2, 4, "tag36h11", 8, missing, missing, 480, 480)
    ts, xy = Fromage.PawsomeTracker.track(file; rectification = rect, start_location = sl, target_width = 12)
    @test length(xy) == nframes
    @test findall(ismissing, xy) == occluded            # a lost tag ⇒ missing, exactly there
    pidx = findall(!ismissing, xy)
    present = [xy[i] for i in pidx]
    # same accuracy contract as the e2e above (checker_size = 8 ⇒ metric unit = ground px),
    # between the first and last frames that actually registered
    ground_disp = hypot((groundpath[pidx[end]] .- groundpath[pidx[1]])...)
    @test hypot((present[end] - present[1])...) ≈ ground_disp rtol = 0.05
    a, b = present[1], present[end]; d = (b - a) ./ hypot((b - a)...)
    @test maximum(abs((p - a)[1] * d[2] - (p - a)[2] * d[1]) for p in present) < 3
end

@testset "AprilTag calibration: failing extrinsic frame is dumped to the issues folder" begin
    # the video has four tags; asking for six fails detection at the extrinsic frame, and the frame
    # is dumped to the issues folder (pointed at a temp dir) for the user to inspect.
    dir = mktempdir(); idir = mktempdir()
    vid, _, _, _ = make_apriltag_video(dir, "drone")
    open(joinpath(dir, "calibs.csv"), "w") do io
        println(io, "calibration_id,type,file,extrinsic,apriltags,family,checker_size")
        println(io, "drone,apriltag,$vid,0,6,tag36h11,12")
    end
    df = Fromage.VerifyRectifications.load_rectifications(dir, joinpath(dir, "calibs.csv"); strict = false, issues_dir = idir)
    @test any(m -> occursin("only 4 of 6 AprilTags", m), only(df.issues))
    @test any(m -> occursin("saved the extrinsic frame", m), only(df.issues))
    pngs = filter(endswith(".png"), readdir(idir))
    @test length(pngs) == 1 && filesize(joinpath(idir, only(pngs))) > 0
end

@testset "diagnostic video: multi-run, mixed calibrations" begin
    # All three rectification kinds in one pipeline run: two only_scale rectifications on
    # different-sized source videos (which used to produce a broken mixed-resolution diagnostic —
    # the fixed canvas makes every segment identical, and the concat-demuxer keeps timestamps
    # strictly monotonic) plus a matlab rectification read from a .mat file.
    dir = mktempdir()
    make_video(joinpath(dir, "cal_big.mp4"); size = (640, 480))
    make_video(joinpath(dir, "cal_small.mp4"); size = (320, 240))
    # fronto-parallel pinhole; ImageSize [480, 640] matches cal_big.mp4 (the cross-check)
    matwrite(joinpath(dir, "cal.mat"), Dict("cameraParams" => Dict(
        "ImageSize" => [480.0, 640.0],
        "K" => [500.0 0.0 320.0; 0.0 500.0 240.0; 0.0 0.0 1.0],
        "RotationVectors" => zeros(2, 3),
        "TranslationVectors" => [0.0 0.0 100.0; 0.0 0.0 200.0],
        "RadialDistortion" => [0.0, 0.0])))
    targets = [make_target_video(dir, "t$i") for i in 1:4]
    open(joinpath(dir, "calibs.csv"), "w") do io
        println(io, "calibration_id,type,file,extrinsic,scale,matlab_file,extrinsic_index")
        println(io, "c1,only_scale,cal_big.mp4,1,1,,")
        println(io, "c2,only_scale,cal_small.mp4,1,1,,")
        println(io, "m1,matlab,cal_big.mp4,1,,cal.mat,1")
    end
    calib_ids = ("c1", "c1", "c2", "m1")
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "run_id,calibration_id,file,start_location")
        for (i, (files, _)) in enumerate(targets)
            println(io, "run$i,$(calib_ids[i]),$(only(files)),\"(55, 50)\"")
        end
    end
    outdir = mktempdir()
    runs = cd(() -> main(dir; tracking_defaults = (target_width = 10,)), outdir)
    @test nrow(runs) == 4
    diag = joinpath(outdir, "results_dir", "diagnostic.mp4")
    sizes, pts, dts = probe_frames(diag)
    @test sizes == Set([(540, 540)])                # one resolution across every frame
    @test length(pts) == 4 * 25                     # 4 runs × 25 written frames each
    @test all(diff(dts) .> 0)                       # decode order strictly monotonic across joins
    @test allunique(pts)                            # every frame has its own presentation time
    # one track csv per run, named by run_id
    for i in 1:4
        lines = readlines(joinpath(outdir, "results_dir", "run$i.csv"))
        @test length(lines) == 51                   # header + 50 coordinates
        @test lines[1] == "time,x,y"
    end
end

end
