@testset "happy path" begin
    @testset "fully valid run validates clean and returns a Run" begin
        runs = check([runrow(start = "0", stop = "4", target_width = "20")])
        @test clean(runs)
        @test runs isa Vector{VR.Run}
        @test length(runs) == 1
        @test length(only(runs).segments) == 1
    end

    @testset "several valid runs, strict returns them without throwing" begin
        # strict=true would throw if any row had an issue
        runs = check([runrow(run_id = "a", file = ART.a),
                      runrow(run_id = "b", file = ART.b, fps = "24"),
                      runrow(run_id = "c", file = ART.a, start_location = "(320, 240)")];
                     strict = true)
        @test runs isa Vector{VR.Run}
        @test length(runs) == 3
        @test all(r -> length(r.segments) == 1, runs)   # each is a distinct one-file run
    end
end
