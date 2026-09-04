@testset "input validation" begin
    # These error unconditionally (before the strict block), so they throw regardless.

    @testset "missing csv file" begin
        @test_throws "missing" VR.load_runs(DATADIR, joinpath(DATADIR, "does_not_exist.csv"))
    end

    @testset "empty csv file" begin
        csv = write_rows(joinpath(DATADIR, "empty.csv"), [])   # header only, no data rows
        @test_throws "csv file is empty" VR.load_runs(DATADIR, csv)
    end

    @testset "unrecognized column" begin
        csv = write_rows(joinpath(DATADIR, "badcol.csv"), [["x", "y"]]; header = ["run_id", "foo"])
        @test_throws "unrecognized column" VR.load_runs(DATADIR, csv)
    end

    @testset "a header with stray whitespace is still recognized" begin
        # `start ` used to arrive as Symbol("start ") and be rejected as an unrecognized column —
        # a loud message for a cause the user cannot see in their spreadsheet. CSV strips header
        # names now, which is the half no cell parser can reach.
        csv = write_rows(joinpath(DATADIR, "padded_header.csv"), [["r", "c", ART.a, "1"]];
                         header = [" run_id", "calibration_id ", " file ", "\tstart"])
        @test clean(VR.load_runs(DATADIR, csv))
    end

    @testset "the split fps column is rejected with a hint" begin
        # `fps` named two rates at once, so it could not be kept as a synonym for either: the
        # message has to say which one the value was, or a run silently changes meaning.
        csv = write_rows(joinpath(DATADIR, "fps_split.csv"), [["c1", "a.mp4", "15"]];
                         header = ["calibration_id", "file", "fps"])
        @test_throws "unrecognized column" VR.load_runs(DATADIR, csv)
        @test_throws "sample_fps" VR.load_runs(DATADIR, csv)
        @test_throws "native_fps" VR.load_runs(DATADIR, csv)
    end

    @testset "the renamed scale column points at downscale, never pixel_width" begin
        # `scale` existed in BOTH csv files meaning unrelated things, so the two gateways carry
        # separate RENAMED_COLUMNS tables. Pointing a runs.csv at calibs.csv's replacement would be
        # worse than the generic message: it names a column this file does not even have.
        csv = write_rows(joinpath(DATADIR, "scale_renamed.csv"), [["c1", "a.mp4", "0.5"]];
                         header = ["calibration_id", "file", "scale"])
        @test_throws "unrecognized column" VR.load_runs(DATADIR, csv)
        @test_throws "scale was renamed to downscale" VR.load_runs(DATADIR, csv)
        err = try VR.load_runs(DATADIR, csv) catch e; sprint(showerror, e) end
        @test !occursin("pixel_width", err)
    end

    @testset "the removed white_point column is now rejected by name (#19)" begin
        # It was accepted and validated but never read, so it was removed rather than implemented.
        # A csv that still carries it is rejected up front, naming the column — the migration is
        # deleting it, and nothing about tracking changes, since the value never reached the tracker.
        csv = write_rows(joinpath(DATADIR, "wp_removed.csv"), [["c1", "a.mp4", "1.0"]];
                         header = ["calibration_id", "file", "white_point"])
        @test_throws "unrecognized column" VR.load_runs(DATADIR, csv)
        @test_throws "white_point" VR.load_runs(DATADIR, csv)
    end
end
