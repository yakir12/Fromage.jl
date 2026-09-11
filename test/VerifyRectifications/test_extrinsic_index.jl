@testset "extrinsic_index bounds" begin
    # A matlab calibration's extrinsic_index selects one of the N extrinsic poses in the .mat file
    # (the row count of TranslationVectors / RotationVectors, both N×3). Valid range is 1 ≤ index ≤ N.

    @testset "matlab_extrinsic_count reads the pose count" begin
        # Counts come off an already-read .mat dict (one matread per file in the pipeline).
        # good.mat / nested.mat both use MATLAB_CALIB_FIELDS -> N poses (nested exercises findfirstkey recursion)
        @test VRect.matlab_extrinsic_count(MAT.matread(joinpath(DATADIR, ART.good_mat))) == MATLAB_N_EXTRINSICS
        @test VRect.matlab_extrinsic_count(MAT.matread(joinpath(DATADIR, ART.nested_mat))) == MATLAB_N_EXTRINSICS
        # translation/rotation pose counts disagree -> an issue string, not a count
        @test VRect.matlab_extrinsic_count(MAT.matread(joinpath(DATADIR, ART.mismatch_mat))) isa String
    end

    @testset "malformed pose vectors are flagged, never thrown" begin
        # `from_matlab` reads both stacks at `[extrinsic_index, [2, 1, 3]]`, so anything that is not
        # an N×3 matrix of numbers cannot be indexed. Every shape here used to reach the builder: the
        # 2×2 of #152 (and the transposed and empty ones) raised a BoundsError from inside it, a
        # non-array raised a MethodError, and none of them named the file or the field. The count
        # check is what they must fail instead.
        #
        # Both stacks are bent the same way, because that is the shape #152 arrived in — and because
        # bending only one leaves the row counts disagreeing, which the pre-existing mismatch check
        # already caught for the wrong reason. The "one stack" set below closes that gap deliberately.
        badpose = (
            text = "nope",                # not an array at all
            scalar = 1.0,
            short = zeros(2, 2),          # #152: two columns, so column 3 is out of bounds
            transposed = zeros(3, 2),     # 3×N written the wrong way round
            flat = zeros(3),              # one vector, not a stack of them
            volume = zeros(2, 3, 1),      # three-dimensional
            strings = fill("x", 2, 3),    # right shape, wrong element type
            empty = zeros(0, 3),          # no poses at all
        )
        for (nm, v) in pairs(badpose)
            @testset "both stacks $nm" begin
                p = joinpath(DATADIR, "badpose_both_$nm.mat")
                make_matlab_with(p; TranslationVectors = v, RotationVectors = v)
                issue = VRect.matlab_extrinsic_count(MAT.matread(p))
                @test issue isa String
                @test occursin("TranslationVectors", issue)      # names the offending field
            end
        end

        # One stack malformed while the row counts still agree: the count check cannot fall back on
        # the mismatch message here, so it is the shape check itself that has to flag the field.
        for k in ("TranslationVectors", "RotationVectors")
            @testset "$k alone" begin
                p = joinpath(DATADIR, "badpose_$(k).mat")
                make_matlab_with(p; NamedTuple{(Symbol(k),)}((zeros(MATLAB_N_EXTRINSICS, 2),))...)
                issue = VRect.matlab_extrinsic_count(MAT.matread(p))
                @test issue isa String
                @test occursin(k, issue)
                @test occursin("expected an N×3 matrix", issue)
            end
        end

        # end-to-end: such a file is flagged and load_rectifications does not throw. The 2×2 case is
        # #152 itself — it passed the count check (returning 2) and blew up in the builder.
        @test flagged(
            check([matlabrow(matlab_file = "badpose_both_text.mat")]),
            1, "expected an N×3 matrix"
        )
        @test flagged(
            check([matlabrow(matlab_file = "badpose_both_short.mat")]),
            1, "expected an N×3 matrix"
        )
        @test flagged(
            check([matlabrow(matlab_file = "badpose_RotationVectors.mat")]),
            1, "expected an N×3 matrix"
        )
        @test flagged(
            check([matlabrow(matlab_file = "badpose_both_empty.mat")]),
            1, "holds no extrinsic poses"
        )
    end

    @testset "in-range index loads clean (both boundaries)" begin
        @test clean(check([matlabrow(extrinsic_index = 1)]))                    # low boundary
        @test clean(check([matlabrow(extrinsic_index = MATLAB_N_EXTRINSICS)]))  # high boundary (pins ≤ N)
    end

    @testset "index must be larger than zero" begin
        @test flagged(check([matlabrow(extrinsic_index = 0)]), 1, "extrinsic_index must be larger than zero")
        @test flagged(check([matlabrow(extrinsic_index = -1)]), 1, "extrinsic_index must be larger than zero")
    end

    @testset "index past the number of poses is flagged" begin
        df = check([matlabrow(extrinsic_index = MATLAB_N_EXTRINSICS + 1)])
        @test flagged(df, 1, "must not exceed the number of extrinsics")
    end

    @testset "translation/rotation pose-count mismatch is flagged" begin
        df = check([matlabrow(matlab_file = ART.mismatch_mat)])
        @test flagged(df, 1, "disagree on the number of extrinsics")
    end
end
