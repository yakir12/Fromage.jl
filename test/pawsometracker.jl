# Direct PawsomeTracker coverage. The former package's test files were dev scratch (they
# referenced a local dataset folder and a hard-coded mounted video), so this compact suite
# replaces them, using the shared synthetic-trajectory generator (test/common.jl): ffmpeg's geq
# renders a disc following a known sine, encoded losslessly so the analytic ground truth is
# exact. (VerifyRuns' test_tracking.jl additionally exercises track through the gateway,
# including anamorphic and scaled variants.)
module PawsomeTrackerTests

using Test
using Fromage.PawsomeTracker: track

include("common.jl")

const DATADIR = mktempdir()

@testset "PawsomeTracker" begin
    base, base_exp = make_target_video(DATADIR, "pt_base")
    light, light_exp = make_target_video(DATADIR, "pt_light"; darker_target = false)
    seg, seg_exp = make_target_video(DATADIR, "pt_seg"; nsegments = 3)
    base_file = joinpath(DATADIR, only(base))

    @testset "single video, explicit start_location" begin
        # window_size = missing must mean "the default" (round(Int, 2target_width)), like a blank csv cell
        _, ij = track(base_file; start_location = (55, 50), target_width = 10, window_size = missing)
        @test length(ij) == 50                       # the full 2 s at 25 fps
        @test tracking_rmse(ij, base_exp) < 1
    end

    @testset "defaults (frame-center start)" begin
        _, ij = track(base_file)
        @test tracking_rmse(ij, base_exp) < 1
    end

    @testset "reduced fps tracks every other frame" begin
        _, ij = track(base_file; fps = 12.5)
        @test length(ij) == 25
        @test tracking_rmse(ij, base_exp; skip = 2) < 1
    end

    @testset "lighter target on dark background" begin
        _, ij = track(joinpath(DATADIR, only(light)); darker_target = false)
        @test tracking_rmse(ij, light_exp) < 1
    end

    @testset "segmented (vector) track" begin
        sls = Vector{Union{Missing, NTuple{2, Int}}}(missing, length(seg))
        sls[1] = (55, 50)                            # later segments continue from the previous one
        # window_size = missing must mean "the default" here too (the vector method's own branch)
        _, ij = track(joinpath.(DATADIR, seg); start_location = sls, window_size = missing)
        @test length(ij) == 50
        @test tracking_rmse(ij, seg_exp) < 1
    end

    @testset "a long-stationary target is not absorbed into the background" begin
        # the disc pauses for 17 s — far longer than the 250-frame rolling background window — which
        # used to absorb it into the per-pixel background model (the model's max saw only the disc
        # at those pixels), erase it from the subtracted image, and set the tracker wandering
        paused, paused_exp = make_target_video(DATADIR, "pt_pause"; duration = 30, pause = (8, 25))
        _, ij = track(joinpath(DATADIR, only(paused)); start_location = (55, 50), target_width = 10)
        @test length(ij) == 750
        @test tracking_rmse(ij, paused_exp) < 1
    end

    @testset "diagnostic file plays at 2× real time" begin
        df = joinpath(DATADIR, "diag.mp4")
        track(base_file; diagnostic_file = df)
        @test isfile(df)
        @test filesize(df) > 0
        # 50 tracked frames at 25 fps: every 2nd written, declared at 2·25/2 = 25 fps
        s = probe_stream(df)
        @test (s.width, s.height) == (640, 360)     # the fixed unrectified canvas
        @test s.nframes == 25
        @test s.fps ≈ 25
    end
end

end
