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
end
