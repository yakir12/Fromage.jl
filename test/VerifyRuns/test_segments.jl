@testset "segmented runs (grouping by run_id)" begin

    @testset "rows sharing a run_id fold into one run, in CSV order" begin
        runs = check([runrow(run_id = "s", file = ART.a, start = "0", stop = "4", start_location = "(100, 100)"),
                      runrow(run_id = "s", file = ART.b, start = "1", stop = "7")])
        @test clean(runs)
        @test length(runs) == 1
        r = only(runs)
        @test length(r.segments) == 2             # two csv rows ⇒ two segments
        @test [basename(s.file) for s in r.segments] == ["a.mp4", "b.mp4"]
        @test [s.start for s in r.segments] == [0.0, 1.0]
        @test [s.stop for s in r.segments]  == [4.0, 7.0]
        # first segment's start_location kept; a non-first segment may omit it (continues from previous)
        @test isequal([s.start_location for s in r.segments], [(100, 100), missing])
    end

    @testset "distinct run_ids stay separate runs" begin
        runs = check([runrow(run_id = "x", file = ART.a),
                      runrow(run_id = "y", file = ART.b)])
        @test clean(runs)
        @test length(runs) == 2
        @test all(r -> length(r.segments) == 1, runs)
        @test [r.run_id for r in runs] == ["x", "y"]
    end

    @testset "segments must agree on run-level parameters" begin
        df = check([runrow(run_id = "c", file = ART.a, target_width = "20"),
                    runrow(run_id = "c", file = ART.b, target_width = "30")])
        @test flagged(df, 1, "run segments disagree on target_width")
        @test flagged(df, 2, "run segments disagree on target_width")
    end

    @testset "segments must agree on background_length (a run-level parameter)" begin
        df = check([runrow(run_id = "b", file = ART.a, background_length = "30"),
                    runrow(run_id = "b", file = ART.b, background_length = "40")])
        @test flagged(df, 1, "run segments disagree on background_length")
        @test flagged(df, 2, "run segments disagree on background_length")
    end

    @testset "segments must agree on the video's pixel dimensions" begin
        # width/height live on the run-level Source, so mixed-dimension segments are rejected
        df = check([runrow(run_id = "d", file = ART.a),
                    runrow(run_id = "d", file = ART.small)])
        @test flagged(df, 1, "run segments disagree on dimension")
        @test flagged(df, 2, "run segments disagree on dimension")
    end

    @testset "a run's segments must agree on calibration_id (required on every row)" begin
        # all segments share the same calibration_id ⇒ clean, carried onto the run
        runs = check([runrow(run_id = "s", file = ART.a, calibration_id = "cal_1"),
                      runrow(run_id = "s", file = ART.b, calibration_id = "cal_1")])
        @test clean(runs)
        @test length(only(runs).segments) == 2
        @test only(runs).calibration_id == "cal_1"

        # omitting it is not allowed: every such segment row is flagged at parse time
        df0 = check([runrow(run_id = "s", file = ART.a, calibration_id = missing),
                     runrow(run_id = "s", file = ART.b, calibration_id = missing)])
        @test flagged(df0, 1, "calibration_id is missing")
        @test flagged(df0, 2, "calibration_id is missing")

        # two different values ⇒ flagged on every segment
        df = check([runrow(run_id = "s", file = ART.a, calibration_id = "cal_1"),
                    runrow(run_id = "s", file = ART.b, calibration_id = "cal_2")])
        @test flagged(df, 1, "run segments disagree on calibration_id")
        @test flagged(df, 2, "run segments disagree on calibration_id")

        # one set, one missing: the omission itself is the issue; the consistency check only
        # compares otherwise-clean rows, so no "disagree" is stacked on top of it
        df2 = check([runrow(run_id = "s", file = ART.a, calibration_id = "cal_1"),
                     runrow(run_id = "s", file = ART.b, calibration_id = missing)])
        @test flagged(df2, 2, "calibration_id is missing")
        @test !flagged(df2, 1, "run segments disagree on calibration_id")
    end

    @testset "a single bad segment fails the whole run load" begin
        # second segment points at a missing file: the load reports it (non-strict ⇒ returns the df)
        df = check([runrow(run_id = "b", file = ART.a),
                    runrow(run_id = "b", file = "no_such.mp4")])
        @test df isa AbstractDataFrame
        @test flagged(df, 2, "file does not exist")
    end

    @testset "imputing the start location leaves the run untouched (#23)" begin
        # A `Run` describes what the csv said; tracking it must not rewrite it. The imputation used
        # to assign into the run's own start locations, so the first `track` baked its `center` into the
        # run — and a later call with a *different* `center` then silently kept the first one, because
        # the coalesce saw a non-missing first element.
        # (`isequal`, not `==`: comparing vectors that contain `missing` yields `missing`.)
        runs = check([runrow(run_id = "m", file = ART.a, start_location = missing),
                      runrow(run_id = "m", file = ART.b)])
        r = only(runs)
        @test length(r.segments) == 2
        before = [s.start_location for s in r.segments]
        @test all(ismissing, before)                  # nothing to impute from the csv

        sls = VR.resolved_segments(r, (7, 9), nothing)
        @test sls[1].start_location == (7, 9)         # the caller gets the resolved segments...
        @test ismissing(sls[2].start_location)        # ...with later segments left alone
        @test sls !== r.segments                      # ...as a vector of its own
        @test isequal([s.start_location for s in r.segments], before)   # run itself unchanged

        # so a second call is free to impute something else
        sls2 = VR.resolved_segments(r, (11, 13), nothing)
        @test sls2[1].start_location == (11, 13)
        @test isequal([s.start_location for s in r.segments], before)

        # the frame-centre fallback (no centre given) must not write back either
        sls3 = VR.resolved_segments(r, missing, nothing)
        @test sls3[1].start_location == VR.frame_center(r.frame)
        @test isequal([s.start_location for s in r.segments], before)
    end

    @testset "...including a one-segment run (#23, #68)" begin
        # A single-video run used to carry its start_location as an immutable scalar field, so this
        # could not go wrong at arity 1. It is a one-element vector now, and every run takes the
        # same imputation path, so the guarantee has to be asserted here too.
        r = only(check([runrow(run_id = "o", start_location = missing)]))
        @test length(r.segments) == 1
        @test all(s -> ismissing(s.start_location), r.segments)
        sls = VR.resolved_segments(r, (7, 9), nothing)
        @test [s.start_location for s in sls] == [(7, 9)]
        @test sls !== r.segments
        @test all(s -> ismissing(s.start_location), r.segments)      # the run itself is untouched
        # so a second call is free
        @test [s.start_location for s in VR.resolved_segments(r, (11, 13), nothing)] == [(11, 13)]
    end
end
