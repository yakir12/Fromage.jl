@testset "strict mode & issue report" begin
    @testset "strict=true throws when issues exist" begin
        @test_throws "there were issues" check([runrow(target_width = "-1")]; strict = true)
    end

    # `runs_report` rather than capturing stdout: the report is a value now, so these assert on the
    # string the gateway builds instead of on a temp file it was redirected into.
    @testset "issue report names the row and its run_id; non-strict returns the df with :issues" begin
        df = check([runrow(target_width = "-1")])
        out = VR.runs_report(df, "runs.csv")
        @test occursin("row 1 (run_id: r): target_width must be larger than zero", out)
        @test !occursin("target_width must be larger than zero,", out)   # join adds no trailing separator
        @test df isa AbstractDataFrame
        @test hasproperty(df, :issues)
    end

    # the gateway is handed the joined path; the report names the file by its own name (#425)
    @testset "the report names the file it read" begin
        _, out = capturing(() -> check("my_trial.csv", [runrow(target_width = "-1")]))
        @test occursin("The following are issues with the my_trial.csv file", out)
        @test !occursin("runs.csv", out)
        @test !occursin(DATADIR, out)
    end

    @testset "auto-assigned run_ids are not repeated in the issue report" begin
        out = VR.runs_report(check([row(rectification_id = "c", file = ART.a, target_width = "-1")]), "runs.csv")
        @test occursin("row 1: target_width must be larger than zero", out)
        @test !occursin("run_id", out)
    end

    # As in the calibration suite: under `strict` an id failure aborts before a video is opened, and
    # ART.corrupt's absence from the report is what proves it (#121).
    @testset "an id failure aborts before any video is opened (#121)" begin
        rows = [
            runrow(run_id = "ok", file = ART.corrupt),
            runrow(run_id = "bad/name", file = ART.a),
        ]
        _, out = capturing() do
            try
                check("tier1_abort.csv", rows; strict = true)
            catch e
                e
            end
        end
        @test occursin("must not contain", out)
        @test !occursin("issue reading from video file", out)
    end

    @testset "without strict the id failure is quarantined, and the rest is still validated" begin
        rows = [
            runrow(run_id = "ok", file = ART.corrupt),
            runrow(run_id = "bad/name", file = ART.a),
        ]
        df, out = capturing(() -> check("tier1_quarantine.csv", rows))
        @test flagged(df, 2, "must not contain")
        @test flagged(df, 1, "issue reading from video file")
        # one report, at the end, not one per tier (#426)
        @test count("must not contain", out) == 1
    end

end
