@testset "input validation" begin
    # These error unconditionally (before the strict block), so they throw regardless.

    @testset "missing csv file" begin
        @test_throws "missing" load_csv(joinpath(DATADIR, "does_not_exist.csv"))
    end

    @testset "empty csv file" begin
        csv = write_rows(joinpath(DATADIR, "empty.csv"), [])   # header only, no data rows
        @test_throws "csv file is empty" load_csv(csv)
    end

    @testset "unknown column is accepted" begin
        csv = write_rows(joinpath(DATADIR, "badcol.csv"), [["x", "y"]]; header = ["run_id", "foo"])
        @test_logs check_csv(csv)
    end

    @testset "user-defined columns are ignored, with typo warnings" begin
        baseline = check_csv(write_rows(joinpath(DATADIR, "without_metadata.csv"), [runrow()]))
        csv = write_rows(
            joinpath(DATADIR, "custom_columns.csv"),
            [vcat(runrow(), ["metadata", "metadata"])];
            header = vcat(HEADER, ["sample_fp", "animal_id"]),
        )
        parsed = @test_logs (:warn, r"sample_fp.*sample_fps.*custom_columns\.csv") check_csv(csv)
        @test isequal(parsed, baseline)

        csv = write_rows(
            joinpath(DATADIR, "custom_feature.csv"),
            [vcat(runrow(), ["metadata"])];
            header = vcat(HEADER, ["custom_feature"]),
        )
        @test_logs load_csv(csv)
    end

    @testset "a header with stray whitespace is still recognized" begin
        # `start ` used to arrive as Symbol("start ") and be treated as separate metadata —
        # a likely typo that the warning policy now catches. CSV strips header
        # names now, which is the half no cell parser can reach.
        csv = write_rows(
            joinpath(DATADIR, "padded_header.csv"), [["r", "c", ART.a, "1"]];
            header = [" run_id", "rectification_id ", " file ", "\tstart"]
        )
        @test clean(load_csv(csv))
    end

    @testset "the split fps column warns with a hint" begin
        # `fps` named two rates at once, so it could not be kept as a synonym for either: the
        # message has to say which one the value was, or a run silently changes meaning.
        csv = write_rows(
            joinpath(DATADIR, "fps_split.csv"), [["c1", "a.mp4", "15"]];
            header = ["rectification_id", "file", "fps"]
        )
        @test_logs (:warn, r"fps.*sample_fps") check_csv(csv)
        @test_logs (:warn, r"fps.*native_fps") check_csv(csv)
    end

    @testset "the renamed scale column points at downscale, never pixel_width" begin
        # `scale` existed in BOTH csv files meaning unrelated things, so the two gateways carry
        # separate RENAMED_COLUMNS tables. Pointing a runs.csv at rectifications.csv's replacement would be
        # worse than the generic message: it names a column this file does not even have.
        csv = write_rows(
            joinpath(DATADIR, "scale_renamed.csv"), [["c1", "a.mp4", "0.5"]];
            header = ["rectification_id", "file", "scale"]
        )
        @test_logs (:warn, r"scale.*downscale") check_csv(csv)
    end

    @testset "the renamed calibration_id column says where it went" begin
        # v0.2.24: the column is required in BOTH csv files, so both gateways carry the entry —
        # a runs.csv naming the old one has to be told, not just handed the generic message.
        csv = write_rows(
            joinpath(DATADIR, "calibid_renamed.csv"), [["c1", "a.mp4"]];
            header = ["calibration_id", "file"]
        )
        @test_logs (:warn, r"calibration_id.*rectification_id") check_csv(csv)
    end

    @testset "the removed white_point column is accepted as metadata" begin
        # It was accepted and validated but never read, so it was removed rather than implemented.
        # A csv that still carries it is accepted as ignored metadata, and nothing about tracking
        # changes, since the value never reached the tracker.
        csv = write_rows(
            joinpath(DATADIR, "wp_removed.csv"), [["c1", "a.mp4", "1.0"]];
            header = ["rectification_id", "file", "white_point"]
        )
        @test_logs check_csv(csv)
    end
end
