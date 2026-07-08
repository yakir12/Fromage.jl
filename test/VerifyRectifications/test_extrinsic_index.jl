@testset "extrinsic_index bounds" begin
    # A matlab calibration's extrinsic_index selects one of the N extrinsic poses in the .mat file
    # (the row count of TranslationVectors / RotationVectors, both N×3). Valid range is 1 ≤ index ≤ N.

    @testset "matlab_extrinsic_count reads the pose count" begin
        # Counts come off an already-read .mat dict (one matread per file in the pipeline).
        # good.mat / nested.mat both use MATLAB_CALIB_FIELDS -> N poses (nested exercises findfirstkey recursion)
        @test VRect.matlab_extrinsic_count(MAT.matread(joinpath(DATADIR, ART.good_mat)))   == MATLAB_N_EXTRINSICS
        @test VRect.matlab_extrinsic_count(MAT.matread(joinpath(DATADIR, ART.nested_mat))) == MATLAB_N_EXTRINSICS
        # translation/rotation pose counts disagree -> an issue string, not a count
        @test VRect.matlab_extrinsic_count(MAT.matread(joinpath(DATADIR, ART.mismatch_mat))) isa String
    end

    @testset "in-range index loads clean (both boundaries)" begin
        @test clean(check("ei_min.csv", [matlabrow(extrinsic_index = 1)]))                    # low boundary
        @test clean(check("ei_max.csv", [matlabrow(extrinsic_index = MATLAB_N_EXTRINSICS)]))  # high boundary (pins ≤ N)
    end

    @testset "index must be larger than zero" begin
        @test flagged(check("ei_zero.csv", [matlabrow(extrinsic_index = 0)]),  1, "extrinsic_index must be larger than zero")
        @test flagged(check("ei_neg.csv",  [matlabrow(extrinsic_index = -1)]), 1, "extrinsic_index must be larger than zero")
    end

    @testset "index past the number of poses is flagged" begin
        df = check("ei_big.csv", [matlabrow(extrinsic_index = MATLAB_N_EXTRINSICS + 1)])
        @test flagged(df, 1, "exceeds the number of extrinsics")
    end

    @testset "translation/rotation pose-count mismatch is flagged" begin
        df = check("ei_mismatch.csv", [matlabrow(matlab_file = ART.mismatch_mat)])
        @test flagged(df, 1, "disagree on the number of extrinsics")
    end
end
