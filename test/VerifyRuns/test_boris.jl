# A BORIS "Tabular events" export as the runs file (#409). The adapter's own rules — pairing,
# splitting at video boundaries, agreement, joining, provenance, its issues — are checked on the
# first tier alone (`parse_runs`, no video opened), so the videos named in those exports need not
# exist. The second tier, FPS check included, runs on the suite's own a.mp4 (5 s) and b.mp4 (8 s),
# both 30 fps.

const BORIS_HEADER = [
    "Observation id", "Observation date", "Description", "Observation duration",
    "Observation type", "Source", "Time offset (s)", "Media duration (s)", "FPS", "Subject",
    "Behavior", "Behavioral category", "Behavior type", "Time", "Media file name", "Image index",
    "Image file path", "Comment",
]

# One BORIS row: an event of `type` at `time`, by default a `Roll` of subject JK in an observation
# of a.mp4 then b.mp4, with `run_id` r and `rectification_id` c. Columns BORIS spells with spaces are
# passed as pairs; any other keyword is a column of that name — a Fromage column or a user's own.
function boris(type, time, cells::Pair...; kw...)
    row = Dict{String, Any}(
        "Observation id" => "obs1", "Observation type" => "Media file(s)",
        "Source" => "player #1:E:/videos/$(ART.a);E:/videos/$(ART.b)", "Time offset (s)" => "0.0",
        "Media duration (s)" => "5.000;8.000", "FPS" => "30.000;30.000", "Subject" => "JK",
        "Behavior" => "Roll", "Behavior type" => type, "Time" => string(time),
        "Media file name" => "E:/videos/$(ART.a)", "Image index" => "0", "Image file path" => "NA",
        "run_id" => "r", "rectification_id" => "c",
    )
    for (k, v) in (cells..., (string(k) => v for (k, v) in kw)...)
        row[k] = v
    end
    return row
end
pair(start, stop, cells::Pair...; kw...) = [boris("START", start, cells...; kw...), boris("STOP", stop, cells...; kw...)]

# BORIS's columns first, in BORIS's order, then whatever else the rows name, in first appearance.
function write_boris(rows; name = "boris_$(CASE[] += 1).csv")
    header = copy(BORIS_HEADER)
    for r in rows, k in sort!(collect(keys(r)))
        k in header || push!(header, k)
    end
    return Harness.write_csv(joinpath(DATADIR, name), [[get(r, k, missing) for k in header] for r in rows], header)
end

# The first tier only: what the adapter and the parser made of the export, before any video.
function derived(rows; behavior = "Roll")
    csv = write_boris(rows)
    return first(VR.parse_runs(DATADIR, csv, basename(csv); defaults = (;), boris_behavior = behavior, progress = false))
end
# By file name: the second tier resolves `file` to a real path, which on Windows need not be the
# temp folder's spelling (`RUNNER~1` against `runneradmin`).
windows(df) = collect(zip(passmissing(basename).(df.file), df.start, df.stop))

@testset "BORIS exports (#409)" begin
    @testset "a clean export is one segment per START/STOP pair, and tracks" begin
        rows = [
            pair(1, 2; run_id = "one")...,
            boris("START", 2.5, "Behavior" => "Dance"; run_id = missing),   # another behaviour, interleaved
            pair(3, 4; run_id = "two")...,
            boris("STOP", 4.5, "Behavior" => "Dance"; run_id = missing),
        ]
        df = check_csv(write_boris(rows))
        @test all(isempty, df.issues)
        @test windows(df) == [(ART.a, 1.0, 2.0), (ART.a, 3.0, 4.0)]
        @test df.boris_fps == [30.0, 30.0]
        @test df.csv_rows == [[1, 2], [4, 5]]           # the export's own rows, Dance's skipped
        runs = VR.build_runs(df)
        @test [r.run_id for r in runs] == ["one", "two"]
    end

    @testset "pairs sharing a run_id are the segments of one run" begin
        rows = [pair(0, 1)..., boris("START", 1.2, "Behavior" => "Dance"; run_id = missing), pair(2, 3)...]
        runs = VR.build_runs(check_csv(write_boris(rows)))
        @test length(only(runs).segments) == 2
        @test [(s.start, s.stop) for s in only(runs).segments] == [(0.0, 1.0), (2.0, 3.0)]
    end

    # A split run's issue names the run's other pairs by the export's own rows (#428). Run y's second
    # pair crosses from a.mp4 into b.mp4, so it is two segments with the same rows — named once, and
    # never as "other" rows of its own segments.
    @testset "a split run names its other pairs by the export's rows" begin
        rows = [
            pair(0, 1; run_id = "x")..., pair(1.5, 2; run_id = "y")...,
            pair(2.5, 3; run_id = "x")..., pair(4, 6; run_id = "y")...,
        ]
        df = derived(rows)
        @test df.csv_rows == [[1, 2], [3, 4], [5, 6], [7, 8], [7, 8]]
        msg = "run_id must be on consecutive rows"
        @test df.issues[1] == ["$msg (this run is also on rows 5 and 6)"]
        @test df.issues[2] == ["$msg (this run is also on rows 7 and 8)"]
        @test df.issues[3] == ["$msg (this run is also on rows 1 and 2)"]
        @test df.issues[4] == df.issues[5] == ["$msg (this run is also on rows 3 and 4)"]
    end

    @testset "boris_behavior chooses the behaviour, Roll by default" begin
        rows = [pair(0, 1)..., pair(2, 3, "Behavior" => "Dance"; run_id = "d")...]
        @test derived(rows).run_id == ["r"]
        @test derived(rows; behavior = "Dance").run_id == ["d"]
        @test windows(derived(rows; behavior = "Dance")) == [(ART.a, 2.0, 3.0)]
    end

    @testset "the export's own headers raise no did-you-mean warning" begin
        # `Comment` is one edit from `comment`; read as a runs.csv it would warn
        csv = write_boris([pair(0, 1, "Comment" => "fine")...])
        @test_logs VR.parse_runs(DATADIR, csv, basename(csv); defaults = (;), boris_behavior = "Roll", progress = false)
        # …while a misspelt Fromage column in the same export still does
        csv = write_boris([pair(0, 1; rectification_ids = "c")...])
        @test_logs (:warn, r"rectification_ids") match_mode = :any VR.parse_runs(DATADIR, csv, basename(csv); defaults = (;), boris_behavior = "Roll", progress = false)
    end

    @testset "file time: Time less the offset, located in player #1's videos" begin
        @test windows(derived(pair(11, 12, "Time offset (s)" => "10.0"))) == [(ART.a, 1.0, 2.0)]
        # into the second video: its own seconds
        @test windows(derived(pair(6, 7))) == [(ART.b, 1.0, 2.0)]
        # the coder's path is another machine's, and only its file name is kept — either separator
        @test windows(derived(pair(0, 1, "Source" => "player #1:C:\\videos\\x.mp4", "Media duration (s)" => "5", "FPS" => "30"))) ==
            [("x.mp4", 0.0, 1.0)]
    end

    @testset "a pair crossing a video boundary is split, one segment per video" begin
        three = ("Source" => "player #1:/v/x.mp4;/v/y.mp4;/v/z.mp4", "Media duration (s)" => "5;8;3", "FPS" => "30;25;30")
        df = derived(pair(4, 14, three...))
        # a window running to its video's end leaves `stop` for the probe, as a blank runs.csv cell does
        @test isequal(windows(df), [("x.mp4", 4.0, missing), ("y.mp4", 0.0, missing), ("z.mp4", 0.0, 1.0)])
        @test df.boris_fps == [30.0, 25.0, 30.0]                 # each its own video's rate
        @test all(==([1, 2]), df.csv_rows)                       # all cite the same two rows
        @test all(==("r"), df.run_id)
        # exactly on a boundary: a START opens the next video, a STOP closes the earlier one
        @test isequal(windows(derived(pair(5, 13, three...))), [("y.mp4", 0.0, missing)])
        # BORIS's three decimals, and the running sum of the durations, are not a boundary miss:
        # 10.1 + 20.2 is 30.299999999999997, and a STOP at 30.3 is the end of the last video
        drift = ("Source" => "player #1:/v/x.mp4;/v/y.mp4", "Media duration (s)" => "10.100;20.200", "FPS" => "30;30")
        df = derived(pair(29, 30.3, drift...))
        @test all(isempty, df.issues) && df.file == ["y.mp4"] && df.start ≈ [18.9] && all(ismissing, df.stop)
        df = derived(pair(10.1004, 11, drift...))      # within half a millisecond of the boundary
        @test df.file == ["y.mp4"] && df.start == [0.0] && df.stop ≈ [0.9]
        # a START and a STOP both on one boundary: one empty window, left to the gateway's own check
        df = derived(pair(5, 5, three...))
        @test windows(df) == [("y.mp4", 0.0, 0.0)] && all(isempty, df.issues)
        # and the very end of the last video is the last video's
        @test isequal(windows(derived(pair(15, 16, three...))), [("z.mp4", 2.0, missing)])
        # split segments run through the second tier like any others
        df = check_csv(write_boris(pair(4, 6)))
        @test all(isempty, df.issues)
        @test windows(df) == [(ART.a, 4.0, 5.0), (ART.b, 0.0, 1.0)]
        @test length(only(VR.build_runs(df)).segments) == 2
    end

    @testset "Fromage columns are honoured, and a pair's rows must agree on them" begin
        df = derived(pair(0, 1; target_width = "12", start_location = "(3, 4)", video_type = "drone"))
        @test df.target_width == [12.0]
        @test isequal(df.start_location, [(3, 4)])
        @test df.video_type == ["drone"]
        rows = [boris("START", 0; target_width = "12"), boris("STOP", 1; target_width = "13")]
        @test flagged(derived(rows), 1, "target_width must be the same on a pair's START and STOP rows")
    end

    @testset "metadata: BORIS's, and the user's own, joined where a pair's rows differ" begin
        # `Modifier #1` and `Arena` stand for a project's modifiers and independent variables,
        # which BORIS writes only when the project has them
        rows = [
            boris("START", 0, "Comment" => "slipped", "Modifier #1" => "fast", "Arena" => "A"; treatment = "IVM", note = "a"),
            boris("STOP", 1, "Comment" => missing, "Modifier #1" => "slow", "Arena" => "A"; treatment = "IVM", note = "b"),
        ]
        df = derived(rows)
        @test df.subject == ["JK"] && df.behavior == ["Roll"] && df.observation_id == ["obs1"]
        @test df.comment == ["slipped | "]
        @test df.treatment == ["IVM"]                  # equal values appear once
        @test df.note == ["a | b"]
        @test df[!, "Modifier #1"] == ["fast | slow"] && df.Arena == ["A"]
        @test all(isempty, df.issues)
    end

    @testset "pairs of different Subjects may share a run_id" begin
        rows = [pair(0, 1)..., pair(2, 3, "Subject" => "C")...]
        df = check_csv(write_boris(rows))
        @test all(isempty, df.issues)
        @test df.subject == ["JK", "C"]
        @test length(only(VR.build_runs(df)).segments) == 2
    end

    @testset "pairing is per Subject" begin
        # JK's and C's pairs interleave; each subject's rows alternate on their own
        rows = [
            boris("START", 0; run_id = "jk"), boris("START", 0.5, "Subject" => "C"; run_id = "c"),
            boris("STOP", 1; run_id = "jk"), boris("STOP", 1.5, "Subject" => "C"; run_id = "c"),
        ]
        df = derived(rows)
        @test df.csv_rows == [[1, 3], [2, 4]]
        @test all(isempty, df.issues)
    end

    @testset "every problem is reported, together, citing the export's rows" begin
        rows = [
            boris("START", 0; run_id = "a"),                               # 1: START with no STOP
            boris("START", 1; run_id = "b"), boris("STOP", 2; run_id = "b"),  # 2–3: clean
            boris("STOP", 3; run_id = "c"),                                # 4: STOP with no START
            boris("POINT", 4; run_id = "d"),                               # 5: a POINT
            pair(5, 6; run_id = missing)...,                               # 6–7: no run_id
            pair(7, 8, "Observation type" => "Live observation"; run_id = "e")...,           # 8–9
            pair(0, 1, "Source" => "player #1:/v/a.mp4|player #2:/v/b.mp4"; run_id = "f")...,  # 10–11
            [boris("START", 0; run_id = "g", rectification_id = "c"), boris("STOP", 1; run_id = "g", rectification_id = "x")]...,  # 12–13
            pair(20, 21; run_id = "h")...,                                 # 14–15: past the videos
            pair(0, 1, "Source" => "/v/a.mp4"; run_id = "i")...,           # 16–17: not a player list
            pair(0, 1, "Media duration (s)" => "5;eight"; run_id = "j")...,  # 18–19
            pair(0, 1, "FPS" => "30"; run_id = "k")...,                    # 20–21: one rate for two videos
            pair(0, "soon"; run_id = "l")...,                              # 22–23
            [boris("START", 7; run_id = "m"), boris("STOP", 2; run_id = "m")]...,  # 24–25: back into the first video
            pair(0, 1, "Time offset (s)" => "x"; run_id = "n")...,         # 26–27
        ]
        df = derived(rows)
        report = VR.runs_report(df, "runs.csv")
        expect = [
            "row 1 (run_id: a): Behavior type must alternate START and STOP within a Subject — this START has no STOP",
            "row 4 (run_id: c): Behavior type must alternate START and STOP within a Subject — this STOP has no START",
            "row 5 (run_id: d): Behavior type must be START or STOP",
            "rows 6 and 7: run_id must be filled on every row of the tracked behaviour in a BORIS export",
            "rows 8 and 9 (run_id: e): Observation type must be Media file(s)",
            "rows 10 and 11 (run_id: f): Source must name a single player",
            "rows 12 and 13 (run_id: g): rectification_id must be the same on a pair's START and STOP rows",
            "rows 14 and 15 (run_id: h): Time must lie within the observation's videos",
            "rows 16 and 17 (run_id: i): wrong Source format",
            "rows 18 and 19 (run_id: j): wrong Media duration (s) format",
            "rows 20 and 21 (run_id: k): FPS must list one rate per video in Source",
            "rows 22 and 23 (run_id: l): wrong Time format",
            "rows 24 and 25 (run_id: m): Time must not be earlier on a STOP row than on its START row",
            "rows 26 and 27 (run_id: n): wrong Time offset (s) format",
        ]
        for line in expect
            @test occursin(line, report)
        end
        @test !occursin("rows 2 and 3", report)              # the clean pair is not reported
        @test !occursin("file is missing", report)           # the export has no `file` column to fill
        @test ismissing(df.file[findfirst(isequal("h"), df.run_id)])
        # the unflagged pair is unharmed by its neighbours
        @test isempty(df.issues[findfirst(isequal("b"), df.run_id)])
        # never thrown, and a strict load stops after reporting
        @test_throws "there were issues" load_csv(write_boris(rows))
    end

    @testset "list lengths that disagree" begin
        df = derived(pair(0, 1, "Media duration (s)" => "5"))
        @test flagged(df, 1, "Media duration (s) must list one duration per video in Source")
    end

    @testset "an export with none of the behaviour is one issue, not a parse of nothing" begin
        df = derived([pair(0, 1, "Behavior" => "Dance")...])
        @test only(df.issues) == ["no START or STOP row has Behavior Roll — boris_behavior names the behaviour to track"]
        @test occursin("every row: no START or STOP row has Behavior Roll", VR.runs_report(df, "runs.csv"))
        # a POINT alone is not a START or STOP either
        @test flagged(derived([boris("POINT", 1)]), 1, "no START or STOP row has Behavior Roll")
    end

    @testset "a blank run_id is never numbered for you" begin
        df = derived([pair(0, 1; run_id = missing)..., pair(2, 3; run_id = missing)...])
        @test all(ismissing, df.run_id)
        @test all(i -> flagged(df, i, "run_id must be filled"), 1:2)
        @test !any(i -> flagged(df, i, "either every row has a run_id or none does"), 1:2)
    end

    @testset "BORIS's FPS must match the video's" begin
        df = check_csv(write_boris(pair(1, 2, "FPS" => "25.000;30.000")))
        @test flagged(df, 1, "FPS must match the frame rate the video file reports")
        @test occursin("rows 1 and 2 (run_id: r): FPS must match", VR.runs_report(df, "runs.csv"))
        # to BORIS's three decimals
        @test all(isempty, check_csv(write_boris(pair(1, 2, "FPS" => "30.0004;30.000"))).issues)
    end

    @testset "a runs.csv carries no BORIS rate, and its report is unchanged" begin
        df = check([runrow(target_width = "-1")])
        @test all(ismissing, df.boris_fps)
        @test df.csv_rows == [[1]]
        @test occursin("row 1 (run_id: r): target_width must be larger than zero", VR.runs_report(df, "runs.csv"))
    end
end
