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

    @testset "timestamps are the true times of the sampled frames (#15, #17)" begin
        # The sampler can only stride whole frames, so the rates it can actually deliver are
        # vid_fps/k. A requested fps in between must still yield a self-consistent track: sample i
        # is raw frame (i-1)*skip, so its timestamp must be start + (i-1)*skip/vid_fps — no more
        # frames than the video holds, and no timestamp implying a frame that was never read.
        v30, _ = make_target_video(DATADIR, "pt_fps30"; fps = 30, duration = 2)
        f30 = joinpath(DATADIR, only(v30))
        meta = probe_stream(f30)
        @test meta.nframes == 60                      # the fixture the cases below assume
        @test meta.fps == 30

        for requested in (30, 25, 20, 17, 12)
            skip = max(1, round(Int, meta.fps / requested))   # the stride the sampler can use
            effective = meta.fps / skip                       # the rate it therefore delivers
            ts, ij = track(f30; fps = requested, start_location = (55, 50), target_width = 10)

            @testset "fps = $requested (skip $skip, effective $(round(effective, digits = 2)))" begin
                # must not run off the end of the video: #15's fps = 20 threw "Could not scale
                # frame". Sample i reads raw frame (i-1)*skip, so it is that index — not the
                # product of the count and the stride — which has to stay inside the video.
                @test (length(ij) - 1) * skip < meta.nframes
                @test length(ts) == length(ij)
                # each timestamp is the true time of the frame it labels — this is both issues:
                # #15 (stride and count disagreeing) and #17 (the one-frame stretch from pinning
                # the last sample to `stop`)
                @test step(ts) ≈ 1 / effective rtol = 1e-9
                @test last(ts) ≈ (length(ts) - 1) / effective rtol = 1e-9
                # and nothing may be labeled at or past the end of the window
                @test last(ts) < 2
            end
        end
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

    @testset "background_length: no subtraction (0) and a short window (30) both track" begin
        # 0 ⇒ the DoG runs on the raw frame (the 2-slice stack only feeds detect the current
        # frame); the clean synthetic scene must track just as well without a background model
        _, ij = track(base_file; start_location = (55, 50), target_width = 10, background_length = 0)
        @test length(ij) == 50
        @test tracking_rmse(ij, base_exp) < 1
        # a short window exercises the rolling phase (50 frames > 30-slice stack) with subtraction on
        _, ij = track(base_file; start_location = (55, 50), target_width = 10, background_length = 30)
        @test tracking_rmse(ij, base_exp) < 1
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
        # the contract as a property of the file itself: playing it takes real_duration/SPEEDUP
        @test s.nframes / s.fps * 2 ≈ 2 rtol = 0.01
    end

    @testset "diagnostic playback speed holds for a non-divisor fps (#55)" begin
        # The check above only covers a divisor rate, where requested == effective and the bug is
        # invisible. The diagnostic declares its framerate from the fps it is handed, so handing it
        # the *requested* rate made it claim the wrong speed: measured on this fixture before the
        # fix, fps = 20 declared 2.67× and fps = 12 declared 1.6×, against a contract of 2×.
        v30, _ = make_target_video(DATADIR, "diag_fps30"; fps = 30, duration = 2)
        f30 = joinpath(DATADIR, only(v30))
        for requested in (30, 25, 20, 12)
            df = joinpath(DATADIR, "diag_$requested.mp4")
            track(f30; fps = requested, start_location = (55, 50), target_width = 10,
                  diagnostic_file = df)
            s = probe_stream(df)
            @testset "fps = $requested" begin
                @test s.nframes > 0
                # playback duration × speedup == the real duration it covers, whatever rate the
                # sampler actually delivered
                @test s.nframes / s.fps * 2 ≈ 2 rtol = 0.01
            end
        end
    end
end

end
