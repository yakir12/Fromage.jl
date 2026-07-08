@testset "parsing" begin
    # Each row starts from a clean baseline; one field is malformed/omitted so the asserted issue is
    # the only thing under test (other checks pass).

    @testset "missing required fields" begin
        @test flagged(check("p_file.csv", [runrow(file = missing)]),   1, "file is missing")
    end

    @testset "calibration_id is required" begin
        # a run is always rectified against a calibration (Fromage joins on calibration_id), so a
        # run without one has nothing to rectify against and is flagged rather than left missing.
        @test only(check("cal_set.csv", [runrow(calibration_id = "cal_42")])).source.calibration_id == "cal_42"
        @test flagged(check("cal_missing.csv", [runrow(calibration_id = missing)]), 1, "calibration_id is missing")
        @test flagged(check("cal_blank.csv",   [runrow(calibration_id = "   ")]),   1, "calibration_id is missing")
    end

    @testset "run_id is all-or-nothing" begin
        # all rows blank (missing or whitespace-only) ⇒ clean, each row its own run, id = row number
        runs = check("p_id_none.csv",
                     [runrow(run_id = missing), runrow(run_id = "   "), runrow(run_id = missing)])
        @test clean(runs)
        @test all(r -> r isa VR.SingleRun, runs)
        @test [r.source.run_id for r in runs] == ["1", "2", "3"]

        # all rows named ⇒ clean, ids used as-is
        runs2 = check("p_id_all.csv", [runrow(run_id = "x"), runrow(run_id = "y")])
        @test clean(runs2)
        @test [r.source.run_id for r in runs2] == ["x", "y"]

        # mixed ⇒ every blank row is flagged, the named row is not
        df = check("p_id_mixed.csv",
                   [runrow(run_id = missing), runrow(run_id = "   "), runrow(run_id = "given")])
        @test flagged(df, 1, "either every row has a run_id or none does")
        @test flagged(df, 2, "either every row has a run_id or none does")
        @test !flagged(df, 3, "either every row has a run_id or none does")

        # the collision this rule forecloses: an explicit "3" plus a blank row can no longer merge
        # into a bogus multi-segment run — the mixed file is rejected outright
        df2 = check("p_id_collide.csv", [runrow(run_id = "3", file = ART.a),
                                         runrow(run_id = missing, file = ART.b)])
        @test flagged(df2, 2, "either every row has a run_id or none does")
        @test !flagged(df2, 1, "either every row has a run_id or none does")
    end

    @testset "blank (whitespace-only) cell is treated as missing" begin
        @test flagged(check("p_blank_file.csv", [runrow(file = "   ")]),   1, "file is missing")
        # an optional field falls back to its default ("." for path) and still resolves
        @test clean(check("p_blank_path.csv", [runrow(path = "  ")]))
    end

    @testset "wrong formats" begin
        @test flagged(check("p_start.csv",  [runrow(start = "not_a_time")]),          1, "wrong start format")
        @test flagged(check("p_stop.csv",   [runrow(stop = "nope")]),                 1, "wrong stop format")
        @test flagged(check("p_tw.csv",     [runrow(target_width = "big")]),          1, "wrong target_width format")
        @test flagged(check("p_sl.csv",     [runrow(start_location = "abc")]),        1, "wrong start_location format")
        @test flagged(check("p_sl2.csv",    [runrow(start_location = "1;2")]),        1, "wrong start_location format")
        # a coordinate that overflows Int64 is a graceful "wrong format", not an uncaught OverflowError
        @test flagged(check("p_sl_ovf.csv", [runrow(start_location = "(10000000000000000000,1)")]), 1, "wrong start_location format")
        @test flagged(check("p_win.csv",    [runrow(window_size = "wide")]),          1, "wrong window_size format")
        @test flagged(check("p_fps.csv",    [runrow(fps = "fast")]),                  1, "wrong fps format")
        @test flagged(check("p_apr.csv",    [runrow(apriltags = "2.5")]),             1, "wrong apriltags format")
        @test flagged(check("p_isf.csv",    [runrow(initial_search_factor = "x")]),   1, "wrong initial_search_factor format")
        @test flagged(check("p_wp.csv",     [runrow(white_point = "x")]),             1, "wrong white_point format")
        @test flagged(check("p_sc.csv",     [runrow(scale = "big")]),                 1, "wrong scale format")
        @test flagged(check("p_dark.csv",   [runrow(darker_target = "maybe")]),       1, "wrong darker_target format")
    end

    @testset "defaults applied (with correct values) when optional fields omitted" begin
        runs = check("p_defaults.csv", [runrow()])   # only run_id + calibration_id + file set
        @test clean(runs)
        r = only(runs)
        @test r isa VR.SingleRun                      # one file ⇒ scalar-field run type
        @test r.source.calibration_id        == "c"   # the baseline's id (required, never defaulted)
        @test r.start                        == 0.0
        @test r.source.target_width          == 25.0
        @test r.source.window_size           === missing
        @test r.start_location               === missing
        @test r.source.darker_target         == true
        @test r.source.apriltags             == 0
        @test r.source.initial_search_factor == 4.0
        @test r.source.white_point           == 1.0
        @test r.source.scale                 == 1.0
    end

    @testset "start/stop accept seconds and HH:MM:SS" begin
        @test clean(check("p_secs.csv",  [runrow(start = "1.0", stop = "3.5")]))
        @test clean(check("p_clock.csv", [runrow(start = "00:00:01", stop = "00:00:03")]))
        @test only(check("p_clock2.csv", [runrow(start = "00:00:02")])).start == 2.0
    end

    @testset "whitespace is trimmed from string fields" begin
        @test clean(check("p_ws_file.csv", [runrow(file = " " * ART.a)]))   # " a.mp4" still resolves
    end

    @testset "low-level parsers" begin
        @testset "MyTemporal: seconds vs HH:MM:SS precedence" begin
            @test VR.mytryparse(VR.MyTemporal, "1.5")      == 1.5
            @test VR.mytryparse(VR.MyTemporal, "90")       == 90.0
            @test VR.mytryparse(VR.MyTemporal, "00:01:30") == 90.0
            @test VR.mytryparse(VR.MyTemporal, "garbage")  === nothing
        end
        @testset "NTuple{2,Int}: accepted forms and rejects" begin
            @test VR.mytryparse(NTuple{2, Int}, "(7,10)")      == (7, 10)
            @test VR.mytryparse(NTuple{2, Int}, "[250, 1]")    == (250, 1)
            @test VR.mytryparse(NTuple{2, Int}, "250,1")       == (250, 1)
            @test VR.mytryparse(NTuple{2, Int}, "  250 , 1  ") == (250, 1)
            @test VR.mytryparse(NTuple{2, Int}, "1,2,3")       === nothing
            @test VR.mytryparse(NTuple{2, Int}, "abc")         === nothing
            @test VR.mytryparse(NTuple{2, Int}, "(10000000000000000000,1)") === nothing
        end
        @testset "MyWindow: Int or (w,h)" begin
            @test VR.mytryparse(VR.MyWindow, "31")      == 31           # scalar side length
            @test VR.mytryparse(VR.MyWindow, "(31,41)") == (31, 41)     # (w, h) tuple
            @test VR.mytryparse(VR.MyWindow, "31, 41")  == (31, 41)
            @test VR.mytryparse(VR.MyWindow, "wide")    === nothing
        end
    end
end
