@testset "extrinsic corner detection" begin
    @testset "checkerboard -> corners detected (no issue)" begin
        # board.mp4 is a checkerboard with n_corners (5,8); detection succeeds, row stays clean.
        @test clean(check("e_ok.csv", [videorow()]))
    end

    @testset "corner detection with blur > 0" begin
        # exercises the gblur branch of `extract`; detection still succeeds on the checkerboard.
        @test clean(check("e_blur.csv", [videorow(blur = 1)]))
    end

    @testset "blank video -> no corners detected" begin
        df = check("e_none.csv", [videorow(file = ART.video, n_corners = (5, 8))])
        @test flagged(df, 1, "no corners detected")
    end

    @testset "a throwing detection is caught as an issue, never thrown" begin
        # corrupt.mp4 fails the probe (width/height stay missing), so the frame read inside
        # extrinsic_issue throws; the catch turns that into an issue instead of aborting the load.
        df = check("e_corrupt.csv", [videorow(file = ART.corrupt)])
        @test flagged(df, 1, "issue with corner detection")
    end

    @testset "a failing extrinsic frame is dumped to the issues folder" begin
        idir = mktempdir()
        # a stale file proves the folder is wiped at the start of each run
        touch(joinpath(idir, "stale.png"))
        df = check("e_dump.csv", [videorow(file = ART.video, n_corners = (5, 8))]; issues_dir = idir)
        @test flagged(df, 1, "no corners detected")
        @test flagged(df, 1, "saved the extrinsic frame")          # the message points at the file
        pngs = filter(endswith(".png"), readdir(idir))
        @test !("stale.png" in pngs)                               # emptied at the start of the run
        @test length(pngs) == 1                                    # exactly the one failing frame
        @test filesize(joinpath(idir, only(pngs))) > 0             # a real, non-empty image
    end
end
