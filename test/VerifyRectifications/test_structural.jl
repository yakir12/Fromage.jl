@testset "structural" begin
    @testset "duplicate rectification_id" begin
        # same id, but otherwise different (different extrinsic) so it is NOT also a duplicate rectification.
        # nonunique flags the repeat (row 2), keeping the first occurrence's id.
        df = check("s_dupid.csv", [videorow(calibration_id = "dup", extrinsic = "00:00:01"),
                                   videorow(calibration_id = "dup", extrinsic = "00:00:03")])
        @test flagged(df, 2, "calibration_id must not repeat")
        @test !flagged(df, 1, "calibration_id must not repeat")
    end

    @testset "different types may now share a source video (no file-type conflict)" begin
        # `file` is always a source video now, so any types can share one physical video — there is no
        # longer a "conflicting types" rule. A video + only_scale (different types) on the same file
        # load clean and are not duplicates.
        df = check("s_vidscale.csv", [videorow(calibration_id = "c1", file = ART.board),
                                      scalerow(calibration_id = "c2", file = ART.board, center = (100, 100), north = (100, 1), scale = 9.5)])
        @test clean(df)
    end

    @testset "a row with a bad type is flagged" begin
        df = check("s_badtype.csv", [videorow(calibration_id = "z1", file = ART.board),
                                     videorow(calibration_id = "z2", file = ART.board, type = "bogus")])
        @test isempty(df.issues[1])              # the valid row is unaffected by its bad-type sibling
        @test flagged(df, 2, "wrong type")
    end

    @testset "duplicate rectification (identical rows)" begin
        # identical in every column except calibration_id -> second is flagged as a duplicate, and since
        # the non-identity params also match it does NOT get the conflicting-parameters issue.
        df = check("s_dupcal.csv", [videorow(calibration_id = "a"),
                                    videorow(calibration_id = "b")])
        @test flagged(df, 2, "duplicate rectification")
        @test !flagged(df, 2, "same rectification with conflicting parameters")
    end

    @testset "video duplicate with conflicting non-identity params" begin
        # Same identity (file, start, stop, extrinsic, center, north) but a different
        # checker_size: still the same rectification, so the 2nd is a duplicate; and because a
        # non-identity parameter disagrees, the duplicate also gets the conflicting-parameters issue.
        df = check("s_dupconflict.csv", [videorow(calibration_id = "k1", checker_size = 4),
                                         videorow(calibration_id = "k2", checker_size = 8)])
        @test flagged(df, 2, "duplicate rectification")
        @test flagged(df, 2, "same rectification with conflicting parameters")
        @test !flagged(df, 1, "duplicate rectification")
        @test !flagged(df, 1, "same rectification with conflicting parameters")
    end

    @testset "video duplicate with conflicting yadif is also flagged" begin
        # yadif is not part of the identity key but two same-identity rows must agree on it: board is
        # progressive (probed false), so an explicit yadif = true on the copy is a parameter conflict.
        df = check("s_dupyadif.csv", [videorow(calibration_id = "y1"),
                                      videorow(calibration_id = "y2", yadif = true)])
        @test flagged(df, 2, "duplicate rectification")
        @test flagged(df, 2, "same rectification with conflicting parameters")
    end

    @testset "video duplicate with conflicting aspect is also flagged" begin
        # likewise aspect: probed 1.0 on row 1, explicit 2.0 on the same-identity copy.
        df = check("s_dupaspect.csv", [videorow(calibration_id = "a1"),
                                       videorow(calibration_id = "a2", aspect = 2.0)])
        @test flagged(df, 2, "duplicate rectification")
        @test flagged(df, 2, "same rectification with conflicting parameters")
    end

    @testset "video NOT a duplicate when an identity field differs" begin
        # center is part of the identity key, so differing center -> distinct rectifications, no flags.
        df = check("s_vidcenter.csv", [videorow(calibration_id = "i1", center = (250, 180)),
                                       videorow(calibration_id = "i2", center = (240, 170))])
        @test !flagged(df, 2, "duplicate rectification")
        @test !flagged(df, 2, "same rectification with conflicting parameters")
    end

    @testset "only_scale duplicate = identical except id/issues" begin
        # only_scale: same iff every field matches (id aside). Identical -> 2nd duplicate;
        # differ on any field (here scale) -> not a duplicate.
        dup = check("s_dupscale.csv", [scalerow(calibration_id = "s1"), scalerow(calibration_id = "s2")])
        @test flagged(dup, 2, "duplicate rectification")
        @test !flagged(dup, 1, "duplicate rectification")
        diff = check("s_diffscale.csv", [scalerow(calibration_id = "s1", scale = 9.5),
                                         scalerow(calibration_id = "s2", scale = 10.5)])
        @test !flagged(diff, 2, "duplicate rectification")
    end

    @testset "matlab duplicate = identical except id/issues" begin
        dup = check("s_dupmat.csv", [matlabrow(calibration_id = "m1"), matlabrow(calibration_id = "m2")])
        @test flagged(dup, 2, "duplicate rectification")
        @test !flagged(dup, 1, "duplicate rectification")
        diff = check("s_diffmat.csv", [matlabrow(calibration_id = "m1", center = (160, 120)),
                                       matlabrow(calibration_id = "m2", center = (100, 100))])
        @test !flagged(diff, 2, "duplicate rectification")
    end

    @testset "duplicate rectification (same file via different path spelling)" begin
        # Same physical file/dir reached through different spellings of path ("." vs "./.").
        # The raw joined :path/:file strings differ, so without canonicalization these escape
        # the duplicate-rectification check; verify_unique_calibrations! realpaths the key columns
        # (in a copy) so the second row is still flagged.
        df = check("s_duppath.csv", [videorow(calibration_id = "p1", path = "."),
                                     videorow(calibration_id = "p2", path = "./.")])
        @test flagged(df, 2, "duplicate rectification")
        @test !flagged(df, 1, "duplicate rectification")
    end

    @testset "no false duplicate from rows nulled by earlier checks" begin
        # two DISTINCT matlab rows (different centers) that are both out of bounds: each center gets
        # nulled by the bounds check, which would otherwise make the rows look identical. Uniqueness
        # skips rows that already carry issues, so neither gets a spurious "duplicate rectification".
        df = check("s_nodup_nulled.csv", [matlabrow(calibration_id = "a", center = (600, 600), north = missing),
                                          matlabrow(calibration_id = "b", center = (700, 700), north = missing)])
        @test flagged(df, 1, "center cannot be larger than the dimensions")
        @test flagged(df, 2, "center cannot be larger than the dimensions")
        @test !flagged(df, 1, "duplicate rectification")
        @test !flagged(df, 2, "duplicate rectification")
    end

    @testset "negative control: same file+type, different extrinsic is fine" begin
        df = check("s_ok.csv", [videorow(calibration_id = "n1", extrinsic = "00:00:01"),
                                videorow(calibration_id = "n2", extrinsic = "00:00:03")])
        @test clean(df)
    end
end
