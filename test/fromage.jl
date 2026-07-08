# End-to-end: a synthetic data folder (one checkerboard calibration video + one trackable run
# video + the two CSVs) driven through `main`, which validates both files, builds the
# rectification, tracks the run with the rectification attached, and writes the concatenated
# diagnostic video into results_dir under the current directory.
module FromageTests

using Test
using Fromage
using DataFrames: DataFrame, nrow

include("common.jl")

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
    t, ij = only(runs.run)                          # each run entry is track's (timestamps, coords)
    @test length(ij) == 50                          # the full 2 s at 25 fps
    @test tracking_rmse(ij, expected) < 1           # tracked against the analytic ground truth
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
end

@testset "diagnostic video: multi-run, mixed calibrations" begin
    # Two only_scale rectifications on different-sized source videos used to produce
    # different-sized diagnostic segments, stream-copied into one broken mixed-resolution track
    # (players decode everything at the first segment's dimensions). The fixed canvas makes every
    # segment identical, and the concat-demuxer keeps timestamps strictly monotonic.
    dir = mktempdir()
    make_video(joinpath(dir, "cal_big.mp4"); size = (640, 480))
    make_video(joinpath(dir, "cal_small.mp4"); size = (320, 240))
    targets = [make_target_video(dir, "t$i") for i in 1:3]
    open(joinpath(dir, "calibs.csv"), "w") do io
        println(io, "calibration_id,type,file,extrinsic,scale")
        println(io, "c1,only_scale,cal_big.mp4,1,1")
        println(io, "c2,only_scale,cal_small.mp4,1,1")
    end
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "run_id,calibration_id,file,start_location")
        for (i, (files, _)) in enumerate(targets)
            println(io, "run$i,$(i < 3 ? "c1" : "c2"),$(only(files)),\"(55, 50)\"")
        end
    end
    outdir = mktempdir()
    runs = cd(() -> main(dir; tracking_defaults = (target_width = 10,)), outdir)
    @test nrow(runs) == 3
    diag = joinpath(outdir, "results_dir", "diagnostic.mp4")
    sizes, pts, dts = probe_frames(diag)
    @test sizes == Set([(540, 540)])                # one resolution across every frame
    @test length(pts) == 3 * 25                     # 3 runs × 25 written frames each
    @test all(diff(dts) .> 0)                       # decode order strictly monotonic across joins
    @test allunique(pts)                            # every frame has its own presentation time
end

end
