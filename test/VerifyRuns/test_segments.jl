@testset "segmented runs (grouping by run_id)" begin

    @testset "rows sharing a run_id fold into one run, in CSV order" begin
        runs = check(
            [
                runrow(run_id = "s", file = ART.a, start = "0", stop = "4", start_location = "(100, 100)"),
                runrow(run_id = "s", file = ART.b, start = "1", stop = "7"),
            ]
        )
        @test clean(runs)
        @test length(runs) == 1
        r = only(runs)
        @test length(r.segments) == 2             # two csv rows ⇒ two segments
        @test [basename(s.file) for s in r.segments] == ["a.mp4", "b.mp4"]
        @test [s.start for s in r.segments] == [0.0, 1.0]
        @test [s.stop for s in r.segments] == [4.0, 7.0]
        # first segment's start_location kept; a non-first segment may omit it (continues from previous)
        @test isequal([s.start_location for s in r.segments], [(100, 100), missing])
    end

    @testset "distinct run_ids stay separate runs" begin
        runs = check(
            [
                runrow(run_id = "x", file = ART.a),
                runrow(run_id = "y", file = ART.b),
            ]
        )
        @test clean(runs)
        @test length(runs) == 2
        @test all(r -> length(r.segments) == 1, runs)
        @test [r.run_id for r in runs] == ["x", "y"]
    end

    @testset "segments must agree on run-level parameters" begin
        df = check(
            [
                runrow(run_id = "c", file = ART.a, target_width = "20"),
                runrow(run_id = "c", file = ART.b, target_width = "30"),
            ]
        )
        @test flagged(df, 1, "run segments disagree on target_width")
        @test flagged(df, 2, "run segments disagree on target_width")
    end

    @testset "segments must agree on background_length (a run-level parameter)" begin
        df = check(
            [
                runrow(run_id = "b", file = ART.a, background_length = "30"),
                runrow(run_id = "b", file = ART.b, background_length = "40"),
            ]
        )
        @test flagged(df, 1, "run segments disagree on background_length")
        @test flagged(df, 2, "run segments disagree on background_length")
    end

    @testset "a native_fps declared on one segment governs the whole run" begin
        # The segments of a run are pieces of one recording, so a rate declared on any of its rows
        # is a claim about all of them. Left to the probe, the blank row would take its own file's
        # 30 and the two would then read as disagreeing — which is what this is here to prevent.
        runs = check(
            [
                runrow(run_id = "n", file = ART.a, start = "0", stop = "4", native_fps = "15"),
                runrow(run_id = "n", file = ART.b, start = "0", stop = "4"),
            ]
        )
        @test clean(runs)
        r = only(runs)
        @test length(r.segments) == 2
        @test r.tuning.native_fps == 15.0
        @test r.tuning.sample_fps == 15.0        # carried through the cascade, once, for the run
    end

    @testset "segments cannot declare different native_fps" begin
        # Both rows claim to describe the same recording, so the two claims cannot both hold and
        # neither may quietly win.
        df = check(
            [
                runrow(run_id = "m", file = ART.a, native_fps = "15"),
                runrow(run_id = "m", file = ART.b, native_fps = "25"),
            ]
        )
        @test flagged(df, 1, "run segments disagree on native_fps")
        @test flagged(df, 2, "run segments disagree on native_fps")
    end

    @testset "segments must agree on the video's pixel dimensions" begin
        # width/height live on the run-level Source, so mixed-dimension segments are rejected
        df = check(
            [
                runrow(run_id = "d", file = ART.a),
                runrow(run_id = "d", file = ART.small),
            ]
        )
        @test flagged(df, 1, "run segments disagree on dimension")
        @test flagged(df, 2, "run segments disagree on dimension")
    end

    @testset "a run's segments must agree on rectification_id (required on every row)" begin
        # all segments share the same rectification_id ⇒ clean, carried onto the run
        runs = check(
            [
                runrow(run_id = "s", file = ART.a, rectification_id = "cal_1"),
                runrow(run_id = "s", file = ART.b, rectification_id = "cal_1"),
            ]
        )
        @test clean(runs)
        @test length(only(runs).segments) == 2
        @test only(runs).rectification_id == "cal_1"

        # omitting it is not allowed: every such segment row is flagged at parse time
        df0 = check(
            [
                runrow(run_id = "s", file = ART.a, rectification_id = missing),
                runrow(run_id = "s", file = ART.b, rectification_id = missing),
            ]
        )
        @test flagged(df0, 1, "rectification_id is missing")
        @test flagged(df0, 2, "rectification_id is missing")

        # two different values ⇒ flagged on every segment
        df = check(
            [
                runrow(run_id = "s", file = ART.a, rectification_id = "cal_1"),
                runrow(run_id = "s", file = ART.b, rectification_id = "cal_2"),
            ]
        )
        @test flagged(df, 1, "run segments disagree on rectification_id")
        @test flagged(df, 2, "run segments disagree on rectification_id")

        # one set, one missing: the omission itself is the issue; the consistency check only
        # compares otherwise-clean rows, so no "disagree" is stacked on top of it
        df2 = check(
            [
                runrow(run_id = "s", file = ART.a, rectification_id = "cal_1"),
                runrow(run_id = "s", file = ART.b, rectification_id = missing),
            ]
        )
        @test flagged(df2, 2, "rectification_id is missing")
        @test !flagged(df2, 1, "run segments disagree on rectification_id")
    end

    @testset "a single bad segment fails the whole run load" begin
        # second segment points at a missing file: the load reports it (non-strict ⇒ returns the df)
        df = check(
            [
                runrow(run_id = "b", file = ART.a),
                runrow(run_id = "b", file = "no_such.mp4"),
            ]
        )
        @test df isa AbstractDataFrame
        @test flagged(df, 2, "file does not exist")
    end

    @testset "imputing the start location leaves the run untouched (#23)" begin
        # A `Run` describes what the csv said; tracking it must not rewrite it. The imputation used
        # to assign into the run's own start locations, so the first `track` baked its `center` into the
        # run — and a later call with a *different* `center` then silently kept the first one, because
        # the coalesce saw a non-missing first element.
        # (`isequal`, not `==`: comparing vectors that contain `missing` yields `missing`.)
        runs = check(
            [
                runrow(run_id = "m", file = ART.a, start_location = missing),
                runrow(run_id = "m", file = ART.b),
            ]
        )
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
        # The literal, not `VR.frame_center(...)`: comparing the function against itself passes
        # whichever order it returns, and (320, 240) is distinguishable from its transpose. a.mp4 is
        # 640x480 at sar 1, and the fallback is display (x, y), so the x comes first.
        @test sls3[1].start_location == (320, 240)
        @test sls3[1].start_location == VR.frame_center(r.frame_format)
        @test isequal([s.start_location for s in r.segments], before)
    end

    @testset "...including a one-segment run (#23, #68)" begin
        # A single-video run used to carry its start_location as an immutable scalar field, so this
        # could not go wrong when a run had just one segment. It is a one-element vector now, and
        # every run takes the same imputation path, so the guarantee has to be asserted here too.
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
    # ---- windows of one file (#153) ---------------------------------------------------------
    # A run's segments may be several windows of ONE file — that is how an untrackable stretch is
    # left out. Times within one file are comparable, so those windows can be checked: each one's
    # `start` must be at or after the previous one's `stop`. Windows of DIFFERENT files are never
    # compared; each file's clock starts at its own zero and nothing relates them.
    OVERLAP = "segments from the same file must not overlap"

    @testset "windows of one file must not overlap" begin
        df = check(
            [
                runrow(run_id = "w", file = ART.a, start = "0", stop = "3"),
                runrow(run_id = "w", file = ART.a, start = "2", stop = "4"),
            ]
        )
        @test flagged(df, 1, OVERLAP)
        @test flagged(df, 2, OVERLAP)
    end

    @testset "windows of one file must not run backwards" begin
        df = check(
            [
                runrow(run_id = "w", file = ART.a, start = "3", stop = "4"),
                runrow(run_id = "w", file = ART.a, start = "0", stop = "1"),
            ]
        )
        @test flagged(df, 1, OVERLAP)
        @test flagged(df, 2, OVERLAP)
    end

    @testset "two identical rows are two overlapping windows" begin
        df = check(
            [
                runrow(run_id = "w", file = ART.a, start = "0", stop = "1"),
                runrow(run_id = "w", file = ART.a, start = "0", stop = "1"),
            ]
        )
        @test flagged(df, 1, OVERLAP)
        @test flagged(df, 2, OVERLAP)
    end

    @testset "touching windows are legal" begin
        # `start` exactly at the previous `stop` is correct: nothing is tracked twice.
        runs = check(
            [
                runrow(run_id = "t", file = ART.a, start = "0", stop = "2"),
                runrow(run_id = "t", file = ART.a, start = "2", stop = "4"),
            ]
        )
        @test clean(runs)
        @test length(only(runs).segments) == 2
    end

    @testset "a gap between two windows is legal" begin
        # The supported way to leave an untrackable stretch out. The gap is closed up in the
        # run's timeline, deliberately (DECISIONS, #153).
        runs = check(
            [
                runrow(run_id = "g", file = ART.a, start = "0", stop = "1"),
                runrow(run_id = "g", file = ART.a, start = "2", stop = "3"),
            ]
        )
        @test clean(runs)
        @test length(only(runs).segments) == 2
    end

    @testset "windows are compared per file, not per adjacent row" begin
        # a, b, a: file a's two windows increase, so the b in between changes nothing.
        runs = check(
            [
                runrow(run_id = "i", file = ART.a, start = "0", stop = "1"),
                runrow(run_id = "i", file = ART.b, start = "0", stop = "1"),
                runrow(run_id = "i", file = ART.a, start = "2", stop = "3"),
            ]
        )
        @test clean(runs)
        @test length(only(runs).segments) == 3

        # ...and the same three rows with file a's windows overlapping flag a's two rows only
        df = check(
            [
                runrow(run_id = "i", file = ART.a, start = "0", stop = "3"),
                runrow(run_id = "i", file = ART.b, start = "0", stop = "1"),
                runrow(run_id = "i", file = ART.a, start = "2", stop = "4"),
            ]
        )
        @test flagged(df, 1, OVERLAP)
        @test !flagged(df, 2, OVERLAP)
        @test flagged(df, 3, OVERLAP)
    end

    @testset "only the offending pair is flagged" begin
        # Three windows of one file, of which only the last two overlap.
        df = check(
            [
                runrow(run_id = "p", file = ART.a, start = "0", stop = "1"),
                runrow(run_id = "p", file = ART.a, start = "2", stop = "4"),
                runrow(run_id = "p", file = ART.a, start = "3", stop = "5"),
            ]
        )
        @test !flagged(df, 1, OVERLAP)
        @test flagged(df, 2, OVERLAP)
        @test flagged(df, 3, OVERLAP)
    end

    @testset "the same file in two different runs is never compared" begin
        # Different runs are unrelated: each may cut whatever window it likes out of the file.
        runs = check(
            [
                runrow(run_id = "u", file = ART.a, start = "0", stop = "3"),
                runrow(run_id = "v", file = ART.a, start = "2", stop = "4"),
            ]
        )
        @test clean(runs)
        @test length(runs) == 2
    end

    @testset "two spellings of one path are one file" begin
        # The comparison keys on the canonical resolved path, so it runs after `resolve_paths!`
        # and is blind to how the cell was spelled.
        df = check(
            [
                runrow(run_id = "s", file = ART.a, start = "0", stop = "3"),
                runrow(run_id = "s", path = "./", file = "./" * ART.a, start = "2", stop = "4"),
            ]
        )
        @test flagged(df, 1, OVERLAP)
        @test flagged(df, 2, OVERLAP)
    end

    @testset "an already-flagged row does not also collect an overlap" begin
        # The second row's window is backwards, which nulls its `start`; without the clean-rows
        # gate the pair would then read as a second, spurious complaint.
        df = check(
            [
                runrow(run_id = "f", file = ART.a, start = "0", stop = "3"),
                runrow(run_id = "f", file = ART.a, start = "4", stop = "2"),
            ]
        )
        @test flagged(df, 2, "start must come before stop")
        @test !flagged(df, 1, OVERLAP)
        @test !flagged(df, 2, OVERLAP)
    end
end
