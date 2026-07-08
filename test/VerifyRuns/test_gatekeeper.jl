# The whole point of the package: a run that VerifyRuns accepts must drive PawsomeTracker.track
# without error. Short (1 s) clips keep this fast while still exercising the real track call.
@testset "gatekeeper: a verified run drives track()" begin
    @testset "single-file run" begin
        runs = check("gk_single.csv", [runrow(run_id = "g1", start = "0", stop = "1", target_width = "20")])
        @test clean(runs)
        t, ij = VR.track(only(runs))
        @test length(t) == length(ij)
        @test all(xy -> length(xy) == 2, ij)   # one (x, y) coordinate per timestamp
    end

    @testset "segmented run across two videos" begin
        runs = check("gk_seg.csv", [runrow(run_id = "g2", file = ART.a, start = "0", stop = "1", start_location = "(100, 100)"),
                                    runrow(run_id = "g2", file = ART.b, start = "0", stop = "1")])
        @test clean(runs)
        t, ij = VR.track(only(runs))
        @test length(t) == length(ij) > 0
    end
end
