@testset "segmented runs (grouping by run_id)" begin

    @testset "rows sharing a run_id fold into one run, in CSV order" begin
        runs = check("seg_two.csv", [runrow(run_id = "s", file = ART.a, start = "0", stop = "4", start_location = "(100, 100)"),
                                     runrow(run_id = "s", file = ART.b, start = "1", stop = "7")])
        @test clean(runs)
        @test length(runs) == 1
        r = only(runs)
        @test r isa VR.MultiRun                # two segments ⇒ vector-field run type
        @test length(r.files) == 2
        @test basename.(r.files) == ["a.mp4", "b.mp4"]
        @test r.starts == [0.0, 1.0]
        @test r.stops  == [4.0, 7.0]
        # first segment's start_location kept; a non-first segment may omit it (continues from previous)
        @test isequal(r.start_locations, [(100, 100), missing])
    end

    @testset "distinct run_ids stay separate runs" begin
        runs = check("seg_distinct.csv", [runrow(run_id = "x", file = ART.a),
                                          runrow(run_id = "y", file = ART.b)])
        @test clean(runs)
        @test length(runs) == 2
        @test all(r -> r isa VR.SingleRun, runs)
        @test [r.run_id for r in runs] == ["x", "y"]
    end

    @testset "segments must agree on run-level parameters" begin
        df = check("seg_conflict.csv", [runrow(run_id = "c", file = ART.a, target_width = "20"),
                                        runrow(run_id = "c", file = ART.b, target_width = "30")])
        @test flagged(df, 1, "run segments disagree on target_width")
        @test flagged(df, 2, "run segments disagree on target_width")
    end

    @testset "segments must agree on the video's pixel dimensions" begin
        # width/height live on the run-level Source, so mixed-dimension segments are rejected
        df = check("seg_dim.csv", [runrow(run_id = "d", file = ART.a),
                                   runrow(run_id = "d", file = ART.small)])
        @test flagged(df, 1, "run segments disagree on dimension")
        @test flagged(df, 2, "run segments disagree on dimension")
    end

    @testset "a MultiRun's segments must agree on calibration_id (required on every row)" begin
        # all segments share the same calibration_id ⇒ clean, carried onto the MultiRun
        runs = check("seg_cal_same.csv", [runrow(run_id = "s", file = ART.a, calibration_id = "cal_1"),
                                          runrow(run_id = "s", file = ART.b, calibration_id = "cal_1")])
        @test clean(runs)
        @test only(runs) isa VR.MultiRun
        @test only(runs).calibration_id == "cal_1"

        # omitting it is no longer allowed: every such segment row is flagged at parse time
        df0 = check("seg_cal_none.csv", [runrow(run_id = "s", file = ART.a, calibration_id = missing),
                                         runrow(run_id = "s", file = ART.b, calibration_id = missing)])
        @test flagged(df0, 1, "calibration_id is missing")
        @test flagged(df0, 2, "calibration_id is missing")

        # two different values ⇒ flagged on every segment
        df = check("seg_cal_diff.csv", [runrow(run_id = "s", file = ART.a, calibration_id = "cal_1"),
                                        runrow(run_id = "s", file = ART.b, calibration_id = "cal_2")])
        @test flagged(df, 1, "run segments disagree on calibration_id")
        @test flagged(df, 2, "run segments disagree on calibration_id")

        # one set, one missing: the omission itself is the issue; the consistency check only
        # compares otherwise-clean rows, so no "disagree" is stacked on top of it
        df2 = check("seg_cal_partial.csv", [runrow(run_id = "s", file = ART.a, calibration_id = "cal_1"),
                                            runrow(run_id = "s", file = ART.b, calibration_id = missing)])
        @test flagged(df2, 2, "calibration_id is missing")
        @test !flagged(df2, 1, "run segments disagree on calibration_id")
    end

    @testset "a single bad segment fails the whole run load" begin
        # second segment points at a missing file: the load reports it (non-strict ⇒ returns the df)
        df = check("seg_badfile.csv", [runrow(run_id = "b", file = ART.a),
                                       runrow(run_id = "b", file = "no_such.mp4")])
        @test df isa AbstractDataFrame
        @test flagged(df, 2, "file does not exist")
    end
end
