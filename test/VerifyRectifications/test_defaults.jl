@testset "global defaults (load_rectifications' defaults kwarg)" begin
    # The hierarchy under test: csv cell → defaults kwarg → hardcoded/probed value.

    @testset "kwarg fills a blank cell; a csv cell wins" begin
        cs = check([videorow(checker_width = missing)]; defaults = (checker_width = 7.5,))
        @test cs isa Vector
        @test only(cs).checker_width == 7.5
        cs = check([videorow(checker_width = 4)]; defaults = (checker_width = 7.5,))
        @test only(cs).checker_width == 4.0
        # n_corners: the hardcoded default (7, 10) would fail detection on the 5×8 board — a clean
        # load proves the kwarg (not the hardcoded value) filled the blank cell
        cs = check([videorow(n_corners = missing)]; defaults = (n_corners = (5, 8),))
        @test cs isa Vector
        @test only(cs).n_corners == (5, 8)
    end

    @testset "yadif kwarg beats the probe" begin
        # board.mp4 is progressive (the probe would impute false); a global yadif wins when blank
        cs = check([videorow(yadif = missing)]; defaults = (yadif = true,))
        @test cs isa Vector
        @test only(cs).yadif == true
    end

    @testset "the apriltag tunables are reachable too (#140)" begin
        # apriltags/family/tag_cell_width were hardcoded in parse_apriltag! and rejected outright by
        # resolve_defaults ("unknown rectification default(s)"), so no caller could set them.
        df = check([apriltagrow()]; defaults = (apriltags = 6, family = "tag25h9", tag_cell_width = 5.0))
        @test df.apriltags[1] == 6
        @test df.family[1] == "tag25h9"
        @test df.tag_cell_width[1] == 5.0

        # the usual hierarchy holds: a csv cell still beats the kwarg
        @test check([apriltagrow(apriltags = 9)]; defaults = (apriltags = 6,)).apriltags[1] == 9

        # and with no kwarg at all, the hardcoded fallbacks are unchanged
        df = check([apriltagrow()])
        @test df.apriltags[1] == 4
        @test df.family[1] == "tag36h11"
        @test df.tag_cell_width[1] == 12.0
    end

    @testset "checker_width and tag_cell_width are separate columns" begin
        # They shared one column until v0.1.57, which is what made a global checker_width silently do
        # nothing to apriltag rows: one key, two incompatible defaults (4.0 vs 12.0).
        df = check([apriltagrow()]; defaults = (checker_width = 5.0,))
        @test ismissing(df.checker_width[1])     # not a column this type reads
        @test df.tag_cell_width[1] == 12.0      # and its own default is untouched by it

        # the converse, for a csv written before the split: reported, with the rename named
        @test flagged(check([apriltagrow(checker_width = 12)]), 1,
                      "checker_width is not used by type apriltag (it was renamed to tag_cell_width)")

        # a nonsensical tag_cell_width is verified like any other value
        @test flagged(check([apriltagrow()]; defaults = (tag_cell_width = -1,)), 1,
                      "tag_cell_width must be larger than zero")
    end

    @testset "bad overrides fail fast; bad values are verified per row" begin
        # non-whitelisted keys: the intrinsic window and only_scale's scale are per-row only
        @test_throws ArgumentError check([videorow()]; defaults = (start = 0,))
        @test_throws ArgumentError check([scalerow()]; defaults = (scale = 9.5,))
        # unconvertible value
        @test_throws ArgumentError check([videorow()]; defaults = (n_corners = "5x8",))
        # a convertible but nonsensical value flows into the normal verification
        @test flagged(check([videorow(checker_width = missing)]; defaults = (checker_width = -1,)),
                      1, "checker_width must be larger than zero")
    end
end
