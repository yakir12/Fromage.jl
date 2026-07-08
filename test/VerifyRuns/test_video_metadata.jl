@testset "video metadata (probe + imputation)" begin
    @testset "stop and fps are imputed from the video" begin
        r = only(check("vm_impute.csv", [runrow()]))   # stop & fps omitted
        @test r.stop ≈ VIDEO_DURATION atol = 0.1        # ← container duration (5 s)
        @test r.source.fps == 30.0                      # ← video frame rate
    end

    @testset "the video's pixel dimensions are carried onto the run's Source" begin
        r = only(check("vm_dims.csv", [runrow()]))
        @test r.source.width  == 640                    # ← probed from the video itself
        @test r.source.height == 480
        @test r.source.sar    == 1                      # square pixels; anamorphic: test_tracking.jl
    end

    @testset "CSV values win over imputation" begin
        r = only(check("vm_explicit.csv", [runrow(stop = "3", fps = "15")]))
        @test r.stop == 3.0
        @test r.source.fps == 15.0
    end

    @testset "corrupt/unreadable video is reported" begin
        @test flagged(check("vm_corrupt.csv", [runrow(file = ART.corrupt)]), 1, "issue reading from video file")
    end
end
