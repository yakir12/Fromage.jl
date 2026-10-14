@testset "strict mode & issue report" begin
    @testset "strict=true throws when issues exist" begin
        @test_throws "there were issues" check([uniformrow(pixel_width = -1)]; strict = true)
    end

    # `rectifications_report` rather than capturing stdout: the report is a value now, so these
    # assert on the string the gateway builds instead of on a temp file it was redirected into.
    @testset "issue report has no trailing separator" begin
        df = check([uniformrow(pixel_width = -1)])
        out = VRect.rectifications_report(df, "rectifications.csv")
        @test occursin("row 1 (rectification_id: s): pixel_width must be larger than zero", out)
        @test !occursin("pixel_width must be larger than zero,", out)   # join(issues, ", ") adds no trailing separator
        @test hasproperty(df, :issues)                            # non-strict returns the df with :issues retained
    end

    # the gateway is handed the joined path; the report names the file by its own name (#425)
    @testset "the report names the file it read" begin
        _, out = capturing(() -> check("my_calibs.csv", [uniformrow(pixel_width = -1)]))
        @test occursin("The following are issues with the my_calibs.csv file", out)
        @test !occursin("rectifications.csv", out)
        @test !occursin(DATADIR, out)
    end

    @testset "a blank rectification_id falls back to the plain row label" begin
        out = VRect.rectifications_report(check([uniformrow(rectification_id = missing, pixel_width = -1)]), "rectifications.csv")
        @test occursin("row 1: ", out)
        @test !occursin("(rectification_id", out)
    end

    # The first tier reads rectification_id and nothing else, so under `strict` an id failure aborts
    # before a single video is opened (#121). ART.corrupt is the proof: probing it produces a loud,
    # specific issue, so its ABSENCE from the report is evidence that nothing was read.
    @testset "an id failure aborts before any video is opened (#121)" begin
        rows = [
            uniformrow(rectification_id = "a", file = ART.corrupt),
            uniformrow(rectification_id = "b"),
            uniformrow(rectification_id = "b"),
        ]
        _, out = capturing() do
            try
                check("tier1_abort.csv", rows; strict = true)
            catch e
                e
            end
        end
        @test occursin("rectification_id must not repeat", out)
        @test !occursin("issue reading from video file", out)
    end

    @testset "without strict the id failure is quarantined, and the rest is still validated" begin
        rows = [
            uniformrow(rectification_id = "a", file = ART.corrupt),
            uniformrow(rectification_id = "b"),
            uniformrow(rectification_id = "b"),
        ]
        df, out = capturing(() -> check("tier1_quarantine.csv", rows))
        @test flagged(df, 3, "rectification_id must not repeat")   # the first tier's finding
        @test flagged(df, 1, "issue reading from video file")    # the second tier ran anyway
        @test count("rectification_id must not repeat", out) == 1   # one report, not one per tier (#426)
    end

end
