@testset "value ranges & temporal" begin
    # baseline a.mp4 is 640×480, 5 s, 30 fps; each row overrides one field.

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
        @test only(check([runrow()])).source.background_length == 250
        # 0 is a real mode: background subtraction off
        runs = check([runrow(background_length = "0")])
        @test clean(runs)
        @test only(runs).source.background_length == 0
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
        # 0.05 s at 5 fps → round(5 × 0.05) = 0 frames
        @test flagged(check([runrow(stop = "0.05", fps = "5")]), 1, "too short to contain a single frame")
        # 0.2 s at 5 fps → exactly one frame, allowed
        @test clean(check([runrow(stop = "0.2", fps = "5")]))
    end

    @testset "fps must be positive and not exceed the video's rate" begin
        @test flagged(check([runrow(fps = "0")]),  1, "fps must be larger than zero")
        @test flagged(check([runrow(fps = "60")]), 1, "fps cannot exceed the video frame rate")
        @test clean(check([runrow(fps = "30")]))   # == video rate is allowed
        @test clean(check([runrow(fps = "10")]))   # below is fine
    end

    @testset "temporal window" begin
        @test flagged(check([runrow(start = "-1")]),                1, "start must be larger than or equal to zero")
        @test flagged(check([runrow(start = "4", stop = "2")]),     1, "start must come before stop")
        @test flagged(check([runrow(stop = "99")]),                 1, "stop can not come after video duration")
        # an inverted window must not also emit a "stop after duration" cascade for an in-range stop
        @test !flagged(check([runrow(start = "4", stop = "2")]),  1, "stop can not come after")
    end
end
