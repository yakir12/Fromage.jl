@testset "parsing" begin
    # Each row starts from a clean baseline; one field is malformed/omitted so the
    # asserted issue is the only thing under test (other checks pass).

    @testset "wrong type value" begin
        df = check("p_type.csv", [videorow(type = "bogus")])
        @test flagged(df, 1, "wrong type")
    end

    @testset "wrong type with no other columns short-circuits" begin
        # A bad type skips parse_{video,matlab,only_scale}!, which are the only emitters of the
        # per-field "… is missing" issues. So a sparse bad-type row (only :type set) should come out
        # with *just* "wrong type" — no cascade of missing-field issues — and load without error.
        df = check("p_type_bare.csv", [row(type = "bogus")])
        @test flagged(df, 1, "wrong type")
        @test !flagged(df, 1, "calibration_id is missing")
        @test !flagged(df, 1, "file is missing")
    end

    @testset "missing required fields" begin
        @test flagged(check("p_id.csv",    [videorow(calibration_id = missing)]), 1, "calibration_id is missing")
        @test flagged(check("p_file.csv",  [videorow(file = missing)]),           1, "file is missing")
        @test flagged(check("p_scale.csv", [scalerow(scale = missing)]),          1, "scale is missing")
        @test flagged(check("p_extr.csv",  [videorow(extrinsic = missing)]),      1, "extrinsic is missing")
        # parse_matlab! / parse_only_scale! are separate hand-written field lists; assert the required
        # fields shared with video are wired in those branches too (not just in parse_video!).
        @test flagged(check("p_id_mat.csv",   [matlabrow(calibration_id = missing)]), 1, "calibration_id is missing")
        @test flagged(check("p_file_mat.csv", [matlabrow(file = missing)]),           1, "file is missing")
        # matlab_file (the .mat) is the matlab-only required path field, separate from the source video `file`
        @test flagged(check("p_matf_mat.csv", [matlabrow(matlab_file = missing)]),    1, "matlab_file is missing")
        # extrinsic_index is the matlab-only required field added alongside the MATLAB struct's extrinsic_index
        @test flagged(check("p_ei_mat.csv",   [matlabrow(extrinsic_index = missing)]), 1, "extrinsic_index is missing")
        # extrinsic is now mandatory for ALL types (it lives in the shared Source struct), not just video
        @test flagged(check("p_extr_mat.csv", [matlabrow(extrinsic = missing)]),      1, "extrinsic is missing")
        @test flagged(check("p_extr_sc.csv",  [scalerow(extrinsic = missing)]),       1, "extrinsic is missing")
        @test flagged(check("p_id_sc.csv",    [scalerow(calibration_id = missing)]),  1, "calibration_id is missing")
        @test flagged(check("p_file_sc.csv",  [scalerow(file = missing)]),            1, "file is missing")
    end

    @testset "blank (whitespace-only) cell is treated as missing" begin
        # a required field reports "is missing" rather than silently becoming an empty string
        @test flagged(check("p_blank_id.csv",   [videorow(calibration_id = "   ")]), 1, "calibration_id is missing")
        @test flagged(check("p_blank_file.csv", [videorow(file = "   ")]),           1, "file is missing")
        # an optional field falls back to its default ("." for path) and still resolves
        @test clean(check("p_blank_path.csv", [videorow(path = "  ")]))
    end

    @testset "wrong formats" begin
        @test flagged(check("p_center.csv",  [videorow(center = "abc")]),            1, "wrong center format")
        # a coordinate that overflows Int64 must be a graceful "wrong format", not an uncaught OverflowError
        @test flagged(check("p_center_ovf.csv", [videorow(center = "(10000000000000000000,1)", north = missing)]), 1, "wrong center format")
        @test flagged(check("p_north.csv",   [videorow(north = "1;2")]),             1, "wrong north format")
        @test flagged(check("p_time.csv",    [videorow(extrinsic = "not_a_time")]),  1, "wrong extrinsic format")
        @test flagged(check("p_ncorn.csv",   [videorow(n_corners = "five")]),        1, "wrong n_corners format")
        @test flagged(check("p_check.csv",   [videorow(checker_size = "big")]),      1, "wrong checker_size format")
        @test flagged(check("p_radial.csv",  [videorow(radial_parameters = "2.5")]), 1, "wrong radial_parameters format")
        @test flagged(check("p_aspect.csv",  [videorow(aspect = "wide")]),           1, "wrong aspect format")
        # malformed center/north on the non-video types (same shared parseto!/mytryparse path, for symmetry)
        @test flagged(check("p_center_mat.csv", [matlabrow(center = "abc")]), 1, "wrong center format")
        @test flagged(check("p_north_sc.csv",   [scalerow(north = "1;2")]),   1, "wrong north format")
        # extrinsic_index must parse as an Int (matlab only)
        @test flagged(check("p_ei_fmt.csv",      [matlabrow(extrinsic_index = "two")]), 1, "wrong extrinsic_index format")
    end

    @testset "start/stop must be paired (both directions)" begin
        @test flagged(check("p_pair1.csv", [videorow(start = "00:00:02", stop = missing)]),     1, "both present or both missing")
        @test flagged(check("p_pair2.csv", [videorow(start = missing, stop = "00:00:08")]),     1, "both present or both missing")
    end

    @testset "a filled column irrelevant to the row's type is flagged" begin
        @test flagged(check("p_irr_vid.csv",  [videorow(scale = 9.5)]),         1, "scale is not used by type video")
        @test flagged(check("p_irr_vid2.csv", [videorow(extrinsic_index = 1)]), 1, "extrinsic_index is not used by type video")
        @test flagged(check("p_irr_mat.csv",  [matlabrow(checker_size = 4)]),   1, "checker_size is not used by type matlab")
        @test flagged(check("p_irr_sc.csv",   [scalerow(n_corners = (5, 8))]),  1, "n_corners is not used by type only_scale")
        # blank cells in irrelevant columns stay fine — mixed-type CSVs share one header
        @test clean(check("p_irr_ok.csv", [videorow(), matlabrow(), scalerow()]))
        # a bad type still short-circuits: no irrelevant-column cascade on top of "wrong type"
        df = check("p_irr_badtype.csv", [videorow(type = "bogus")])
        @test flagged(df, 1, "wrong type")
        @test !flagged(df, 1, "is not used by type")
    end

    @testset "north without center" begin
        # verify_center2north is called from a separate branch of parse_row per type; assert all three
        # call sites, not just video (the matlab/only_scale wiring was the original 2.1 bug).
        @test flagged(check("p_n2c.csv",       [videorow(center = missing, north = (250, 1))]), 1, "supplying north without center")
        @test flagged(check("p_n2c_mat.csv",   [matlabrow(center = missing, north = (160, 1))]), 1, "supplying north without center")
        @test flagged(check("p_n2c_scale.csv", [scalerow(center = missing, north = (320, 1))]),  1, "supplying north without center")
    end

    @testset "defaults applied (with correct values) when optional fields omitted" begin
        df = check("p_defaults.csv", [videorow(n_corners = missing, checker_size = missing,
                                               temporal_step = missing, radial_parameters = missing, blur = missing)])
        @test df.n_corners[1]         == (7, 10)
        @test df.checker_size[1]      == 4.0
        @test df.temporal_step[1]     == 2.0
        @test df.radial_parameters[1] == 1
        @test df.blur[1]              == 1.0
    end

    @testset "whitespace is trimmed from string fields" begin
        # a stray space in a hand-edited cell must not break matching.
        @test clean(check("p_ws_type.csv", [videorow(type = "video ")]))          # "video " -> video, not "wrong type"
        @test clean(check("p_ws_file.csv", [videorow(file = " " * ART.board)]))    # " board.mp4" still resolves
        # leading/trailing space on an id is trimmed, so two such ids collide and the repeat is caught
        df = check("p_ws_id.csv", [videorow(calibration_id = "dup",  extrinsic = "00:00:01"),
                                   videorow(calibration_id = "dup ", extrinsic = "00:00:03")])
        @test flagged(df, 2, "calibration_id must not repeat")
    end

    @testset "extrinsic accepts seconds and HH:MM:SS" begin
        @test clean(check("p_secs.csv",  [videorow(extrinsic = "1.0")]))
        @test clean(check("p_clock.csv", [videorow(extrinsic = "00:00:01")]))
    end

    @testset "low-level parsers" begin
        @testset "MyTemporal: seconds vs HH:MM:SS precedence" begin
            @test VRect.mytryparse(VRect.MyTemporal, "1.5")      == 1.5    # float path taken before Time
            @test VRect.mytryparse(VRect.MyTemporal, "90")       == 90.0
            @test VRect.mytryparse(VRect.MyTemporal, "00:01:30") == 90.0   # clock converted to seconds
            @test VRect.mytryparse(VRect.MyTemporal, "garbage")  === nothing
        end
        @testset "NTuple{2,Int}: accepted forms and rejects" begin
            @test VRect.mytryparse(NTuple{2, Int}, "(7,10)")      == (7, 10)
            @test VRect.mytryparse(NTuple{2, Int}, "[250, 1]")    == (250, 1)   # bracket form
            @test VRect.mytryparse(NTuple{2, Int}, "250,1")       == (250, 1)   # bare form
            @test VRect.mytryparse(NTuple{2, Int}, "  250 , 1  ") == (250, 1)   # surrounding whitespace
            @test VRect.mytryparse(NTuple{2, Int}, "1,2,3")       === nothing   # not a 2-tuple
            @test VRect.mytryparse(NTuple{2, Int}, "abc")         === nothing
            @test VRect.mytryparse(NTuple{2, Int}, "(10000000000000000000,1)") === nothing  # >Int64 overflows -> nothing, not a throw
        end
        @testset "type defaults to video when column absent or empty" begin
            @test VRect.parse_row((file = "x.mp4", extrinsic = "00:00:01"))[:type] == "video"
            @test VRect.parse_row((type = missing, file = "x.mp4"))[:type] == "video"
        end
    end
end
