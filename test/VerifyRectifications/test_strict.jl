@testset "strict mode & issue report" begin
    @testset "strict=true throws when issues exist" begin
        @test_throws "there were issues" check("st_throw.csv", [scalerow(scale = -1)]; strict = true)
    end

    @testset "issue report is printed with no trailing separator" begin
        df, out = load_capturing("st_msg.csv", [scalerow(scale = -1)])
        @test occursin("row 1 (calibration_id: s): scale must be larger than zero", out)
        @test !occursin("scale must be larger than zero,", out)   # join(issues, ", ") adds no trailing separator
        @test hasproperty(df, :issues)                            # non-strict returns the df with :issues retained
    end

    @testset "a blank calibration_id falls back to the plain row label" begin
        _, out = load_capturing("st_blank_id.csv", [scalerow(calibration_id = missing, scale = -1)])
        @test occursin("row 1: ", out)
        @test !occursin("(calibration_id", out)
    end
end
