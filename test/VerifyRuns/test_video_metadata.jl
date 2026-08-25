@testset "video metadata (probe + imputation)" begin
    @testset "stop and both rates are imputed from the video" begin
        r = only(check([runrow()]))   # stop, native_fps & sample_fps all omitted
        @test only(r.segments).stop ≈ VIDEO_DURATION atol = 0.1 # ← container duration (5 s)
        @test r.tuning.native_fps == 30.0               # ← video frame rate
        @test r.tuning.sample_fps == 30.0               # ← native_fps, not the probe a second time
    end

    @testset "the video's pixel dimensions are carried onto the run's Source" begin
        r = only(check([runrow()]))
        @test r.frame.width  == 640                    # ← probed from the video itself
        @test r.frame.height == 480
        @test r.frame.sar    == 1                      # square pixels; anamorphic: test_tracking.jl
    end

    @testset "the video's own frame rate is carried onto the run's Tuning" begin
        # The gateway probes it once and carries it, so `track` never reopens the video to read it
        # back — one fewer open of the share per run, and the rate the run was verified against is
        # the rate it is sampled at.
        r = only(check([runrow()]))
        @test r.tuning.native_fps == 30.0
        # an explicit sample_fps does not disturb it: the two are different numbers
        r2 = only(check([runrow(sample_fps = "15")]))
        @test r2.tuning.sample_fps == 15.0 && r2.tuning.native_fps == 30.0
    end

    @testset "a declared native_fps replaces the probe, and carries sample_fps with it" begin
        # The point of the split: the file says 30, the row says 25, and 25 is what the run is both
        # sampled at and timestamped by — without having to also write 25 in a second column.
        r = only(check([runrow(native_fps = "25")]))
        @test r.tuning.native_fps == 25.0
        @test r.tuning.sample_fps == 25.0
        # unless sample_fps says otherwise, which is the whole point of them being independent
        r2 = only(check([runrow(native_fps = "25", sample_fps = "5")]))
        @test r2.tuning.native_fps == 25.0 && r2.tuning.sample_fps == 5.0
    end

    @testset "CSV values win over imputation" begin
        r = only(check([runrow(stop = "3", sample_fps = "15")]))
        @test only(r.segments).stop == 3.0
        @test r.tuning.sample_fps == 15.0
    end

    @testset "corrupt/unreadable video is reported" begin
        @test flagged(check([runrow(file = ART.corrupt)]), 1, "issue reading from video file")
    end

    # parse_framerate moved to test/probing.jl with its import: VerifyRuns reaches the rate
    # through `native_framerate` now, so the raw parser is no longer part of this gateway's surface.
    @testset "parse_sar: undefined ratios fall back to square pixels" begin
        @test VR.parse_sar("64:45") == 64//45
        @test VR.parse_sar("1:1")   == 1//1
        @test VR.parse_sar("N/A")   == 1//1
        @test VR.parse_sar("0:1")   == 1//1             # undefined
        @test VR.parse_sar("")      == 1//1
    end
end
