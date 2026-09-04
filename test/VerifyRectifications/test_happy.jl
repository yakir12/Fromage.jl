@testset "happy path" begin
    @testset "fully valid video validates clean" begin
        df = check([checkerboardrow()])
        @test clean(df)
    end

    @testset "mixed valid (video + matlab + uniform), strict returns a df without throwing" begin
        # strict=true would throw if any row had an issue
        df = check([checkerboardrow(), matlabrow(), uniformrow()]; strict = true)
        @test clean(df)
    end
end
