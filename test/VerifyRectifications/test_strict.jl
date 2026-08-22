@testset "strict mode & issue report" begin
    @testset "strict=true throws when issues exist" begin
        @test_throws "there were issues" check([scalerow(scale = -1)]; strict = true)
    end

    @testset "issue report is printed with no trailing separator" begin
        df, out = load_capturing([scalerow(scale = -1)])
        @test occursin("row 1 (calibration_id: s): scale must be larger than zero", out)
        @test !occursin("scale must be larger than zero,", out)   # join(issues, ", ") adds no trailing separator
        @test hasproperty(df, :issues)                            # non-strict returns the df with :issues retained
    end

    @testset "a blank calibration_id falls back to the plain row label" begin
        _, out = load_capturing([scalerow(calibration_id = missing, scale = -1)])
        @test occursin("row 1: ", out)
        @test !occursin("(calibration_id", out)
    end
    # The first tier reads calibration_id and nothing else, so under `strict` an id failure aborts
    # before a single video is opened (#121). ART.corrupt is the proof: probing it produces a loud,
    # specific issue, so its ABSENCE from the report is evidence that nothing was read.
    @testset "an id failure aborts before any video is opened (#121)" begin
        rows = [scalerow(calibration_id = "a", file = ART.corrupt),
                scalerow(calibration_id = "b"),
                scalerow(calibration_id = "b")]
        _, out = capturing() do
            try
                check("tier1_abort.csv", rows; strict = true)
            catch e
                e
            end
        end
        @test occursin("calibration_id must not repeat", out)
        @test !occursin("issue reading from video file", out)
    end

    @testset "without strict the id failure is quarantined, and the rest is still validated" begin
        rows = [scalerow(calibration_id = "a", file = ART.corrupt),
                scalerow(calibration_id = "b"),
                scalerow(calibration_id = "b")]
        df = check("tier1_quarantine.csv", rows)
        @test flagged(df, 3, "calibration_id must not repeat")   # the first tier's finding
        @test flagged(df, 1, "issue reading from video file")    # the second tier ran anyway
    end

end
