@testset "intrinsic window corner detection" begin
    # verify_intrinsics! samples the calibs window and demands ≥ 3 frames with detectable corners
    # (the temporal_step arithmetic only guarantees 3 *sampled* frames). mixed.mp4 is a checkerboard
    # for 0–2 s and cornerless testsrc after, so the window placement decides the outcome while the
    # extrinsic (at 1 s, on the board) always detects.

    @testset "window on the board portion loads clean" begin
        # 0, 0.9, 1.8 — three samples, all on the board
        @test clean(check("i_ok.csv", [mixedrow()]))
    end

    @testset "window over cornerless footage is flagged" begin
        # 2.5, 3.5, 4.5 — three samples, all on the testsrc tail
        df = check("i_none.csv", [mixedrow(start = "2.5", stop = "4.5", temporal_step = 1)])
        @test flagged(df, 1, "fewer than 3 frames with detectable corners")
    end

    @testset "window with only 2 detectable frames is flagged" begin
        # 0, 1, 2, 3, 4 — only 0 and 1 land on the board: 2 detections < 3
        df = check("i_two.csv", [mixedrow(start = "0", stop = "4", temporal_step = 1)])
        @test flagged(df, 1, "fewer than 3 frames with detectable corners")
    end

    @testset "rows that already failed the extrinsic check are not re-scanned" begin
        # video.mp4 has no corners anywhere: the extrinsic check flags it first, and the (expensive)
        # window scan must then skip the row instead of piling on a second issue.
        df = check("i_skip.csv", [videorow(file = ART.video)])
        @test flagged(df, 1, "no corners detected")
        @test !flagged(df, 1, "fewer than 3 frames with detectable corners")
    end
end
