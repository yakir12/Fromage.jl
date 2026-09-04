@testset "extrinsic corner detection" begin
    @testset "checkerboard -> corners detected (no issue)" begin
        # board.mp4 is a checkerboard with n_corners (5,8); detection succeeds, row stays clean.
        @test clean(check([checkerboardrow()]))
    end

    @testset "corner detection with blur > 0" begin
        # exercises the gblur branch of `extract`; detection still succeeds on the checkerboard.
        @test clean(check([checkerboardrow(blur = 1)]))
    end

    @testset "blank video -> no corners detected" begin
        df = check([checkerboardrow(file = ART.video, n_corners = (5, 8))])
        @test flagged(df, 1, "no corners detected")
    end

    @testset "a throwing detection is caught as an issue, never thrown" begin
        # The gateway never reaches corner detection with an unreadable file — verify_extrinsics!
        # skips rows already flagged, so the probe catches it first (see the testset below), which
        # is exactly why this path has no end-to-end coverage. Call it directly: a throw out of
        # get_corners must become an issue string rather than escape and kill the verification run.
        issue = VRect.extrinsic_issue(joinpath(DATADIR, ART.corrupt), 0.5, missing, 0.0, 640, 480, (7, 10))
        @test issue isa String
        @test occursin("issue with corner detection", issue)
        # ...and it says what happened, in one sentence. Interpolating the raw exception dumped the
        # entire failed ffmpeg `Cmd` — environment block and all, ~8 kB of it — straight into the
        # user-facing issues report (same reasoning as Probing.probe_failure).
        @test occursin("ffmpeg could not read the frame", issue)
        @test !occursin("LD_LIBRARY_PATH", issue)
        @test length(issue) < 200
        # This fixture is genuinely truncated, and now says so in ffmpeg's own words. The report
        # used to assert "the file is corrupt, truncated, or not a video" for EVERY failed read,
        # including a share that merely reconnected mid-open — the one case where that sentence
        # is false and sends the user looking at their data instead of their mount.
        @test occursin("moov atom not found", issue)
    end

    @testset "an unreadable video is reported once, not once per check" begin
        # verify_extrinsics! used to be the only frame-reading check that did not skip flagged
        # rows, so a file the probe had already rejected was re-read here and reported a second
        # time. One unreadable file is one issue.
        df = check([checkerboardrow(file = ART.corrupt)])
        @test flagged(df, 1, "issue reading from video file")
        @test !flagged(df, 1, "issue with corner detection")
        @test length(df.issues[1]) == 1
    end

    @testset "failures are shown in full" begin
        # Nothing is substituted any more: a failed read arrives as a FrameReadError carrying
        # ffmpeg's own (short) stderr, and the rest say something specific about this file — a
        # DimensionMismatch is what an empty seek reshapes into — so all of them reach the user
        # verbatim.
        e = DimensionMismatch("new dimensions (640, 480) must be consistent with array length 0")
        @test VRect._failure_message(e) == sprint(showerror, e)
        @test occursin("array length 0", VRect._failure_message(e))
    end

    @testset "a failing extrinsic frame is dumped to the issues folder" begin
        idir = mktempdir()
        # a file of the caller's own proves the folder they named is only ever added to (#86)
        touch(joinpath(idir, "stale.png"))
        df = check([checkerboardrow(file = ART.video, n_corners = (5, 8))]; issues_dir = idir)
        @test flagged(df, 1, "no corners detected")
        @test flagged(df, 1, "saved the extrinsic frame")          # the message points at the file
        @test isfile(joinpath(idir, "stale.png"))                  # nothing of the caller's is removed
        run_dir = only(filter(isdir, readdir(idir; join = true)))   # this run's own folder
        pngs = filter(endswith(".png"), readdir(run_dir; join = true))
        @test length(pngs) == 1                                    # exactly the one failing frame
        @test filesize(only(pngs)) > 0                             # a real, non-empty image
    end
end
