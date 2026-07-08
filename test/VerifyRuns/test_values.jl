@testset "value ranges & temporal" begin
    # baseline a.mp4 is 640×480, 5 s, 30 fps; each row overrides one field.

    @testset "start_location bounds" begin
        @test flagged(check("v_sl_small.csv", [runrow(start_location = "(0, 100)")]),   1, "start_location cannot be smaller than 1")
        @test flagged(check("v_sl_big.csv",   [runrow(start_location = "(700, 100)")]), 1, "start_location is outside the frame")
        # only one coordinate out of bounds still trips it
        @test flagged(check("v_sl_y.csv",     [runrow(start_location = "(100, 700)")]), 1, "start_location is outside the frame")
        # on the boundary is allowed (checks are strict < 1 and > dimension)
        @test clean(check("v_sl_edge.csv",    [runrow(start_location = "(640, 480)")]))
    end

    @testset "scalar field ranges" begin
        @test flagged(check("v_tw.csv",   [runrow(target_width = "-3")]),           1, "target_width must be larger than zero")
        @test flagged(check("v_tw0.csv",  [runrow(target_width = "0")]),            1, "target_width must be larger than zero")
        @test flagged(check("v_win.csv",  [runrow(window_size = "0")]),             1, "window_size must be larger than zero")
        @test flagged(check("v_wint.csv", [runrow(window_size = "(0, 5)")]),        1, "window_size must be larger than zero")
        @test flagged(check("v_apr.csv",  [runrow(apriltags = "-1")]),              1, "apriltags cannot be negative")
        @test flagged(check("v_isf.csv",  [runrow(initial_search_factor = "0")]),   1, "initial_search_factor must be larger than zero")
        @test flagged(check("v_wp.csv",   [runrow(white_point = "0")]),             1, "white_point must be larger than zero")
        # apriltags == 0 is fine (the default: no tags)
        @test clean(check("v_apr0.csv",   [runrow(apriltags = "0")]))
    end

    @testset "scale must be in (0, 1]" begin
        @test flagged(check("v_sc0.csv",   [runrow(scale = "0")]),    1, "scale must be larger than zero")
        @test flagged(check("v_scneg.csv", [runrow(scale = "-0.5")]), 1, "scale must be larger than zero")
        # > 1 would artificially enlarge the frames
        @test flagged(check("v_schi.csv",  [runrow(scale = "1.5")]),  1, "scale cannot be larger than one")
        @test clean(check("v_sc1.csv",     [runrow(scale = "1")]))      # exactly one (no scaling) is allowed
        @test clean(check("v_sclo.csv",    [runrow(scale = "0.5")]))
    end

    @testset "the scaled target width must span at least one pixel" begin
        # each factor is individually valid; the product is degenerate
        @test flagged(check("v_sctw.csv",  [runrow(target_width = "2", scale = "0.1")]), 1, "smaller than one pixel")
        # scale omitted (defaults to 1): a sub-pixel target_width alone also trips it
        @test flagged(check("v_sctw2.csv", [runrow(target_width = "0.5")]),              1, "smaller than one pixel")
        # exactly one pixel is allowed
        @test clean(check("v_sctw3.csv",   [runrow(target_width = "2", scale = "0.5")]))
    end

    @testset "the temporal window must contain at least one frame" begin
        # 0.05 s at 5 fps → round(5 × 0.05) = 0 frames
        @test flagged(check("v_nf0.csv", [runrow(stop = "0.05", fps = "5")]), 1, "too short to contain a single frame")
        # 0.2 s at 5 fps → exactly one frame, allowed
        @test clean(check("v_nf1.csv",   [runrow(stop = "0.2", fps = "5")]))
    end

    @testset "fps must be positive and not exceed the video's rate" begin
        @test flagged(check("v_fps0.csv", [runrow(fps = "0")]),  1, "fps must be larger than zero")
        @test flagged(check("v_fpshi.csv",[runrow(fps = "60")]), 1, "fps cannot exceed the video frame rate")
        @test clean(check("v_fpseq.csv",  [runrow(fps = "30")]))   # == video rate is allowed
        @test clean(check("v_fpslo.csv",  [runrow(fps = "10")]))   # below is fine
    end

    @testset "temporal window" begin
        @test flagged(check("v_sneg.csv", [runrow(start = "-1")]),                1, "start must be larger than or equal to zero")
        @test flagged(check("v_order.csv",[runrow(start = "4", stop = "2")]),     1, "start must come before stop")
        @test flagged(check("v_sdur.csv", [runrow(stop = "99")]),                 1, "stop can not come after video duration")
        # an inverted window must not also emit a "stop after duration" cascade for an in-range stop
        @test !flagged(check("v_order2.csv", [runrow(start = "4", stop = "2")]),  1, "stop can not come after")
    end
end
