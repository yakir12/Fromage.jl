@testset "strict mode & issue report" begin
    @testset "strict=true throws when issues exist" begin
        @test_throws "there were issues" check([runrow(target_width = "-1")]; strict = true)
    end

    @testset "issue report is printed; non-strict returns the df with :issues" begin
        df, out = load_capturing([runrow(target_width = "-1")])
        @test occursin("row 1 (run_id: r): target_width must be larger than zero", out)
        @test !occursin("target_width must be larger than zero,", out)   # join adds no trailing separator
        @test df isa AbstractDataFrame
        @test hasproperty(df, :issues)
    end

    @testset "auto-assigned run_ids are not repeated in the issue report" begin
        _, out = load_capturing([row(calibration_id = "c", file = ART.a, target_width = "-1")])
        @test occursin("row 1: target_width must be larger than zero", out)
        @test !occursin("run_id", out)
    end
    # As in the calibration suite: under `strict` an id failure aborts before a video is opened, and
    # ART.corrupt's absence from the report is what proves it (#121).
    @testset "an id failure aborts before any video is opened (#121)" begin
        rows = [runrow(run_id = "ok", file = ART.corrupt),
                runrow(run_id = "bad/name", file = ART.a)]
        _, out = capturing() do
            try
                check("tier1_abort.csv", rows; strict = true)
            catch e
                e
            end
        end
        @test occursin("cannot appear in a file name", out)
        @test !occursin("issue reading from video file", out)
    end

    @testset "without strict the id failure is quarantined, and the rest is still validated" begin
        rows = [runrow(run_id = "ok", file = ART.corrupt),
                runrow(run_id = "bad/name", file = ART.a)]
        df = check("tier1_quarantine.csv", rows)
        @test flagged(df, 2, "cannot appear in a file name")
        @test flagged(df, 1, "issue reading from video file")
    end

end
