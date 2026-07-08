@testset "global defaults (load_runs' defaults kwarg)" begin
    # The hierarchy under test: csv cell → defaults kwarg → hardcoded/probed value.

    @testset "kwarg fills a blank cell; a csv cell wins" begin
        runs = check("d_tw.csv", [runrow()]; defaults = (target_width = 60,))
        @test clean(runs)
        @test only(runs).source.target_width == 60.0
        runs = check("d_tw2.csv", [runrow(target_width = 30)]; defaults = (target_width = 60,))
        @test only(runs).source.target_width == 30.0
    end

    @testset "fps kwarg beats the probe" begin
        # a.mp4 runs at 30 fps (the probe would impute 30); a global fps wins when the cell is
        # blank, and still passes the ≤ video-frame-rate check
        runs = check("d_fps.csv", [runrow()]; defaults = (fps = 15,))
        @test clean(runs)
        @test only(runs).source.fps == 15.0
    end

    @testset "window_size accepts a scalar or a (w, h) tuple" begin
        @test only(check("d_win.csv",  [runrow()]; defaults = (window_size = 31,))).source.window_size == 31
        @test only(check("d_win2.csv", [runrow()]; defaults = (window_size = (31, 41),))).source.window_size == (31, 41)
    end

    @testset "bad overrides fail fast; bad values are verified per row" begin
        # non-whitelisted key (the temporal window is per-row only)
        @test_throws ArgumentError check("d_unknown.csv", [runrow()]; defaults = (start = 0,))
        # unconvertible value
        @test_throws ArgumentError check("d_badtype.csv", [runrow()]; defaults = (darker_target = "yes",))
        # a convertible but nonsensical value flows into the normal verification
        @test flagged(check("d_range.csv", [runrow()]; defaults = (target_width = -5,)),
                      1, "target_width must be larger than zero")
    end
end
