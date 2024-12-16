using Fromage
using Test

@testset "Fromage.jl" begin
    main("example")
    @test isdir("tracks and calibrations")
end
