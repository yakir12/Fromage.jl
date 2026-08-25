@testset "global defaults (load_runs' defaults kwarg)" begin
    # The hierarchy under test: csv cell → defaults kwarg → hardcoded/probed value.

    @testset "kwarg fills a blank cell; a csv cell wins" begin
        runs = check([runrow()]; defaults = (target_width = 60,))
        @test clean(runs)
        @test only(runs).tuning.target_width == 60.0
        runs = check([runrow(target_width = 30)]; defaults = (target_width = 60,))
        @test only(runs).tuning.target_width == 30.0
    end

    @testset "sample_fps kwarg beats the probe" begin
        # a.mp4 runs at 30 fps (the probe would impute 30 through native_fps); a global sample_fps
        # wins when the cell is blank, and still passes the ≤ native_fps check
        runs = check([runrow()]; defaults = (sample_fps = 15,))
        @test clean(runs)
        @test only(runs).tuning.sample_fps == 15.0
        @test only(runs).tuning.native_fps == 30.0      # untouched: it is the other rate
    end

    @testset "native_fps kwarg beats the probe, and moves sample_fps with it" begin
        # The cascade runs the same way from a global default as from a cell: nothing here names a
        # sampling rate, so it follows the declared native one rather than the probed 30.
        runs = check([runrow()]; defaults = (native_fps = 25,))
        @test clean(runs)
        @test only(runs).tuning.native_fps == 25.0
        @test only(runs).tuning.sample_fps == 25.0
        # and a cell still wins over the global default, on either of them
        runs = check([runrow(native_fps = "10")]; defaults = (native_fps = 25, sample_fps = 5))
        @test only(runs).tuning.native_fps == 10.0 && only(runs).tuning.sample_fps == 5.0
    end

    @testset "window_size accepts a scalar or a (w, h) tuple" begin
        @test only(check([runrow()]; defaults = (window_size = 31,))).tuning.window_size == 31
        @test only(check([runrow()]; defaults = (window_size = (31, 41),))).tuning.window_size == (31, 41)
    end

    @testset "bad overrides fail fast; bad values are verified per row" begin
        # non-whitelisted key (the temporal window is per-row only)
        @test_throws ArgumentError check([runrow()]; defaults = (start = 0,))
        # unconvertible value
        @test_throws ArgumentError check([runrow()]; defaults = (darker_target = "yes",))
        # a convertible but nonsensical value flows into the normal verification
        @test flagged(check([runrow()]; defaults = (target_width = -5,)),
                      1, "target_width must be larger than zero")
    end
end
