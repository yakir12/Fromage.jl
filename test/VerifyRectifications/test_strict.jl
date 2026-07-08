@testset "strict mode & issue report" begin
    @testset "strict=true throws when issues exist" begin
        @test_throws "there were issues" check("st_throw.csv", [scalerow(scale = -1)]; strict = true)
    end

    @testset "issue report is printed with no trailing separator" begin
        df, out = load_capturing("st_msg.csv", [scalerow(scale = -1)])
        @test occursin("row 1: scale must be larger than zero", out)
        @test !occursin("scale must be larger than zero,", out)   # join(issues, ", ") adds no trailing separator
        @test hasproperty(df, :issues)                            # non-strict returns the df with :issues retained
    end
end
