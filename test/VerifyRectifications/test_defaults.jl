@testset "global defaults (load_rectifications' defaults kwarg)" begin
    # The hierarchy under test: csv cell → defaults kwarg → hardcoded/probed value.

    @testset "kwarg fills a blank cell; a csv cell wins" begin
        cs = check("d_check.csv", [videorow(checker_size = missing)]; defaults = (checker_size = 7.5,))
        @test cs isa Vector
        @test only(cs).checker_size == 7.5
        cs = check("d_check2.csv", [videorow(checker_size = 4)]; defaults = (checker_size = 7.5,))
        @test only(cs).checker_size == 4.0
        # n_corners: the hardcoded default (7, 10) would fail detection on the 5×8 board — a clean
        # load proves the kwarg (not the hardcoded value) filled the blank cell
        cs = check("d_nc.csv", [videorow(n_corners = missing)]; defaults = (n_corners = (5, 8),))
        @test cs isa Vector
        @test only(cs).n_corners == (5, 8)
    end

    @testset "yadif kwarg beats the probe" begin
        # board.mp4 is progressive (the probe would impute false); a global yadif wins when blank
        cs = check("d_yadif.csv", [videorow(yadif = missing)]; defaults = (yadif = true,))
        @test cs isa Vector
        @test only(cs).yadif == true
    end

    @testset "a global scale makes only_scale's scale optional" begin
        cs = check("d_scale.csv", [scalerow(scale = missing)]; defaults = (scale = 9.5,))
        @test cs isa Vector
        @test only(cs).scale == 9.5
        # still required without the kwarg
        @test flagged(check("d_scale2.csv", [scalerow(scale = missing)]), 1, "scale is missing")
    end

    @testset "bad overrides fail fast; bad values are verified per row" begin
        # non-whitelisted key (the intrinsic window is per-row only)
        @test_throws ArgumentError check("d_unknown.csv", [videorow()]; defaults = (start = 0,))
        # unconvertible value
        @test_throws ArgumentError check("d_badtype.csv", [videorow()]; defaults = (n_corners = "5x8",))
        # a convertible but nonsensical value flows into the normal verification
        @test flagged(check("d_range.csv", [videorow(checker_size = missing)]; defaults = (checker_size = -1,)),
                      1, "checker_size must be larger than zero")
    end
end
