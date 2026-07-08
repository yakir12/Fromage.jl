@testset "happy path" begin
    @testset "fully valid video validates clean" begin
        df = check("h_video.csv", [videorow()])
        @test clean(df)
    end

    @testset "mixed valid (video + matlab + only_scale), strict returns a df without throwing" begin
        # strict=true would throw if any row had an issue
        df = check("h_mixed.csv", [videorow(), matlabrow(), scalerow()]; strict = true)
        @test clean(df)
    end
end
