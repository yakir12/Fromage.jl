@testset "strict mode & issue report" begin
    @testset "strict=true throws when issues exist" begin
        @test_throws "there were issues" check([uniformrow(pixel_width = -1)]; strict = true)
    end

    # `rectifications_report` rather than capturing stdout: the report is a value now, so these
    # assert on the string the gateway builds instead of on a temp file it was redirected into.
    @testset "issue report has no trailing separator" begin
        df = check([uniformrow(pixel_width = -1)])
        out = VRect.rectifications_report(df)
        @test occursin("row 1 (rectification_id: s): pixel_width must be larger than zero", out)
        @test !occursin("pixel_width must be larger than zero,", out)   # join(issues, ", ") adds no trailing separator
        @test hasproperty(df, :issues)                            # non-strict returns the df with :issues retained
    end

    @testset "a blank rectification_id falls back to the plain row label" begin
        out = VRect.rectifications_report(check([uniformrow(rectification_id = missing, pixel_width = -1)]))
        @test occursin("row 1: ", out)
        @test !occursin("(rectification_id", out)
    end

    # The first tier reads rectification_id and nothing else, so under `strict` an id failure aborts
    # before a single video is opened (#121). ART.corrupt is the proof: probing it produces a loud,
    # specific issue, so its ABSENCE from the report is evidence that nothing was read.
    @testset "an id failure aborts before any video is opened (#121)" begin
        rows = [uniformrow(rectification_id = "a", file = ART.corrupt),
                uniformrow(rectification_id = "b"),
                uniformrow(rectification_id = "b")]
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
        rows = [uniformrow(rectification_id = "a", file = ART.corrupt),
                uniformrow(rectification_id = "b"),
                uniformrow(rectification_id = "b")]
        df = check("tier1_quarantine.csv", rows)
        @test flagged(df, 3, "rectification_id must not repeat")   # the first tier's finding
        @test flagged(df, 1, "issue reading from video file")    # the second tier ran anyway
    end

end
