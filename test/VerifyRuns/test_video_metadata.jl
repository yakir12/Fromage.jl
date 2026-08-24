@testset "video metadata (probe + imputation)" begin
    @testset "stop and fps are imputed from the video" begin
        r = only(check([runrow()]))   # stop & fps omitted
        @test only(r.segments).stop ≈ VIDEO_DURATION atol = 0.1 # ← container duration (5 s)
        @test r.tuning.fps == 30.0                      # ← video frame rate
    end

    @testset "the video's pixel dimensions are carried onto the run's Source" begin
        r = only(check([runrow()]))
        @test r.frame.width  == 640                    # ← probed from the video itself
        @test r.frame.height == 480
        @test r.frame.sar    == 1                      # square pixels; anamorphic: test_tracking.jl
    end

    @testset "the video's own frame rate is carried onto the run's Source" begin
        # The gateway already probes it (it imputes a blank `fps` from it and bounds-checks an
        # explicit one against it). Carrying it means `track` no longer reopens the video to read it
        # back — one fewer open of the share per run.
        r = only(check([runrow()]))
        @test r.tuning.video_fps == 30.0
        # an explicit tracking fps does not disturb it: the two are different numbers
        r2 = only(check([runrow(fps = "15")]))
        @test r2.tuning.fps == 15.0 && r2.tuning.video_fps == 30.0
    end

    @testset "CSV values win over imputation" begin
        r = only(check([runrow(stop = "3", fps = "15")]))
        @test only(r.segments).stop == 3.0
        @test r.tuning.fps == 15.0
    end

    @testset "corrupt/unreadable video is reported" begin
        @test flagged(check([runrow(file = ART.corrupt)]), 1, "issue reading from video file")
    end

    @testset "parse_framerate: tryparse semantics, never a throw" begin
        # ffprobe reports r_frame_rate as "num/den", or occasionally a bare number.
        @test VR.parse_framerate("30000/1001") ≈ 29.97 atol = 0.01
        @test VR.parse_framerate("25")   == 25.0
        @test VR.parse_framerate("25/1") == 25.0
        @test VR.parse_framerate("25/0") == 25.0        # undefined rate: fall back to the numerator
        # Anything unparseable is `nothing`, so probe_video reports malformed output rather than
        # letting a `parse` throw into its catch. "N/A" is the interesting case: it contains
        # a '/', so it took the fraction branch and split into ("N", "A").
        @test VR.parse_framerate("N/A") === nothing
        @test VR.parse_framerate("")    === nothing
        @test VR.parse_framerate("abc") === nothing
        @test VR.parse_framerate("1/2/3") === nothing
    end

    @testset "parse_sar: undefined ratios fall back to square pixels" begin
        @test VR.parse_sar("64:45") == 64//45
        @test VR.parse_sar("1:1")   == 1//1
        @test VR.parse_sar("N/A")   == 1//1
        @test VR.parse_sar("0:1")   == 1//1             # undefined
        @test VR.parse_sar("")      == 1//1
    end
end
