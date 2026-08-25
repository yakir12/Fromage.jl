@testset "value ranges & temporal" begin
    # baseline a.mp4 is 640×480, 5 s, 30 fps; each row overrides one field.

    @testset "run_id must be usable as a file name" begin
        # It becomes results_dir/<run_id>.csv and the diagnostic segments. Caught in the gateway,
        # where a bad value is one reported row, rather than as a SystemError out of save2csv after
        # every run has already been tracked.
        for bad in ("a/b", "a\\b", "a:b", "..", "a?b")
            @testset "run_id = $(repr(bad))" begin
                @test flagged(check([runrow(run_id = bad)]), 1, "run_id")
            end
        end
        # legal file-name characters stay legal: an apostrophe is escaped into ffmpeg's concat list
        # (see the concatenate test in test/fromage.jl), not rejected here
        @test clean(check([runrow(run_id = "beetle's run")]))
        @test clean(check([runrow(run_id = "run 01")]))
    end

    @testset "start_location bounds" begin
        @test flagged(check([runrow(start_location = "(0, 100)")]),   1, "start_location cannot be smaller than 1")
        @test flagged(check([runrow(start_location = "(700, 100)")]), 1, "start_location is outside the frame")
        # only one coordinate out of bounds still trips it
        @test flagged(check([runrow(start_location = "(100, 700)")]), 1, "start_location is outside the frame")
        # on the boundary is allowed (checks are strict < 1 and > dimension)
        @test clean(check([runrow(start_location = "(640, 480)")]))
    end

    @testset "scalar field ranges" begin
        @test flagged(check([runrow(target_width = "-3")]),           1, "target_width must be larger than zero")
        @test flagged(check([runrow(target_width = "0")]),            1, "target_width must be larger than zero")
        @test flagged(check([runrow(window_size = "0")]),             1, "window_size must be larger than zero")
        @test flagged(check([runrow(window_size = "(0, 5)")]),        1, "window_size must be larger than zero")
        @test flagged(check([runrow(initial_search_factor = "0")]),   1, "initial_search_factor must be larger than zero")
    end

    @testset "scale must be in (0, 1]" begin
        @test flagged(check([runrow(scale = "0")]),    1, "scale must be larger than zero")
        @test flagged(check([runrow(scale = "-0.5")]), 1, "scale must be larger than zero")
        # > 1 would artificially enlarge the frames
        @test flagged(check([runrow(scale = "1.5")]),  1, "scale cannot be larger than one")
        @test clean(check([runrow(scale = "1")]))      # exactly one (no scaling) is allowed
        @test clean(check([runrow(scale = "0.5")]))
    end

    @testset "the scaled target width must span at least one pixel" begin
        # each factor is individually valid; the product is degenerate
        @test flagged(check([runrow(target_width = "2", scale = "0.1")]), 1, "smaller than one pixel")
        # scale omitted (defaults to 1): a sub-pixel target_width alone also trips it
        @test flagged(check([runrow(target_width = "0.5")]),              1, "smaller than one pixel")
        # exactly one pixel is allowed
        @test clean(check([runrow(target_width = "2", scale = "0.5")]))
    end

    @testset "background_length is 0 (no subtraction) or at least 25" begin
        # blank cell ⇒ the hardcoded default (mirrors PawsomeTracker's own)
        @test only(check([runrow()])).tuning.background_length == 250
        # 0 is a real mode: background subtraction off
        runs = check([runrow(background_length = "0")])
        @test clean(runs)
        @test only(runs).tuning.background_length == 0
        @test clean(check([runrow(background_length = "25")]))    # the boundary is allowed
        # 1–24 and negatives are rejected by the same check
        msg = "background_length must be 0 (disables background subtraction) or at least 25"
        @test flagged(check([runrow(background_length = "1")]),  1, msg)
        @test flagged(check([runrow(background_length = "24")]), 1, msg)
        @test flagged(check([runrow(background_length = "-5")]), 1, msg)
        # a non-integer cell fails at parse time, before the range check
        @test flagged(check([runrow(background_length = "2.5")]), 1, "wrong background_length format")
    end

    @testset "the temporal window must contain at least one frame" begin
        # 0.05 s at 5 samples/s → round(5 × 0.05) = 0 frames
        @test flagged(check([runrow(stop = "0.05", sample_fps = "5")]), 1, "too short to contain a single frame")
        # 0.2 s at 5 samples/s → exactly one frame, allowed
        @test clean(check([runrow(stop = "0.2", sample_fps = "5")]))
    end

    @testset "both rates must be larger than zero" begin
        @test flagged(check([runrow(sample_fps = "0")]),  1, "sample_fps must be larger than zero")
        @test flagged(check([runrow(native_fps = "0")]),  1, "native_fps must be larger than zero")
        @test flagged(check([runrow(native_fps = "-5")]), 1, "native_fps must be larger than zero")
    end

    @testset "sample_fps cannot exceed native_fps" begin
        @test flagged(check([runrow(sample_fps = "60")]), 1, "sample_fps cannot exceed native_fps")
        @test clean(check([runrow(sample_fps = "30")]))   # == the video's own rate is allowed
        @test clean(check([runrow(sample_fps = "10")]))   # below is fine
        # bounded by the DECLARED rate, not the probed one: 20 is under the file's 30 and over the
        # 15 this row says the file really runs at
        @test flagged(check([runrow(native_fps = "15", sample_fps = "20")]), 1, "sample_fps cannot exceed native_fps")
        @test clean(check([runrow(native_fps = "15", sample_fps = "15")]))
    end

    @testset "native_fps cannot exceed the rate the file reports" begin
        # a.mp4 is 30 fps. `start`/`stop` stay in the file's own seconds whatever the declaration,
        # so claiming 60 claims twice the frames the window holds and the sampler would run off the
        # end of the video partway through the run.
        msg = "native_fps cannot exceed the frame rate the video file reports"
        @test flagged(check([runrow(native_fps = "60")]), 1, msg)
        @test clean(check([runrow(native_fps = "30")]))   # == what the file reports
        @test clean(check([runrow(native_fps = "15")]))   # below it: the case worth declaring
        # The two bounds chain, which is the invariant that matters: sample_fps ≤ native_fps ≤ what
        # the file reports, so no sampling rate above the file's own can reach the tracker.
        # Inflating native_fps to carry a high sample_fps past the check above does not work —
        # 40 ≤ 60 passes that one, and this rejects the row on the declaration instead.
        @test flagged(check([runrow(native_fps = "60", sample_fps = "40")]), 1, msg)
    end

    @testset "temporal window" begin
        @test flagged(check([runrow(start = "-1")]),                1, "start must be larger than or equal to zero")
        @test flagged(check([runrow(start = "4", stop = "2")]),     1, "start must come before stop")
        @test flagged(check([runrow(stop = "99")]),                 1, "stop can not come after video duration")
        # an inverted window must not also emit a "stop after duration" cascade for an in-range stop
        @test !flagged(check([runrow(start = "4", stop = "2")]),  1, "stop can not come after")
    end
end
