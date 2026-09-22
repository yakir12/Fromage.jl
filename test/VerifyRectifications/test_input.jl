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
        csv = write_rows(joinpath(DATADIR, "badcol.csv"), [["x", "y"]]; header = ["rectification_id", "foo"])
        @test_logs check_csv(csv)
    end

    @testset "user-defined columns are ignored, with typo warnings" begin
        baseline = check_csv(write_rows(joinpath(DATADIR, "without_metadata.csv"), [checkerboardrow()]))
        csv = write_rows(
            joinpath(DATADIR, "custom_columns.csv"),
            [vcat(checkerboardrow(), ["metadata", "metadata"])];
            header = vcat(HEADER, ["checker_widths", "animal_id"]),
        )
        parsed = @test_logs (:warn, r"checker_widths.*checker_width.*custom_columns\.csv") check_csv(csv)
        @test isequal(parsed, baseline)

        csv = write_rows(
            joinpath(DATADIR, "transposed_column.csv"),
            [vcat(checkerboardrow(), ["metadata"])];
            header = vcat(HEADER, ["checker_widht"]),
        )
        @test_logs (:warn, r"checker_widht.*checker_width") load_csv(csv)

        csv = write_rows(
            joinpath(DATADIR, "custom_feature.csv"),
            [vcat(checkerboardrow(), ["metadata"])];
            header = vcat(HEADER, ["custom_feature"]),
        )
        @test_logs load_csv(csv)

        csv = write_rows(
            joinpath(DATADIR, "retired_typo.csv"), [vcat(checkerboardrow(), ["metadata"])];
            header = vcat(HEADER, ["checker_szie"]),
        )
        @test_logs (:warn, r"checker_szie.*retired column 'checker_size'.*tag_cell_width") load_csv(csv)
    end

    # A retired column is the one metadata name that benefits from a migration hint: checker_size
    # split into checker_width (video) and tag_cell_width (apriltag) in v0.1.58.
    @testset "a renamed column says where it went" begin
        csv = write_rows(
            joinpath(DATADIR, "renamedcol.csv"), [["c", "4"]];
            header = ["rectification_id", "checker_size"]
        )
        @test_logs (:warn, r"checker_size.*checker_width") check_csv(csv)
        @test_logs (:warn, r"checker_size.*tag_cell_width") check_csv(csv)
    end

    # The v0.2.23 and v0.2.24 vocabulary migrations. Each old name is accepted as ignored metadata,
    # with a warning naming its replacement — the user's file was correct when they wrote it.
    @testset "renamed columns say where they went" begin
        for (old, new) in (
                (:scale, "pixel_width"), (:start, "intrinsic_start"), (:stop, "intrinsic_stop"),
                (:calibration_id, "rectification_id"),
            )
            @testset "$old → $new" begin
                csv = write_rows(
                    joinpath(DATADIR, "renamed_$old.csv"), [["c", "1"]];
                    header = ["rectification_id", string(old)]
                )
                @test_logs (:warn, Regex("$old.*$new")) check_csv(csv)
            end
        end
        # rectifications.csv's `scale` and runs.csv's `scale` went to different places; this file must never
        # be pointed at the other one's replacement.
        csv = write_rows(
            joinpath(DATADIR, "renamed_scale_only.csv"), [["c", "1"]];
            header = ["rectification_id", "scale"]
        )
        @test_logs (:warn, r"scale.*pixel_width") check_csv(csv)
    end

    # A retired `type` VALUE cannot be caught by RENAMED_COLUMNS: the column name is still valid, so
    # `read_rows` passes it through and only the row parser sees it. Without RENAMED_TYPES the
    # commonest legacy value produced a bare "wrong type".
    @testset "a renamed type value says where it went" begin
        for (old, new) in (("video", "checkerboard"), ("only_scale", "uniform"))
            @testset "type = $old" begin
                csv = write_rows(
                    joinpath(DATADIR, "renamed_type_$old.csv"), [["c", ART.video, old, "1"]];
                    header = ["rectification_id", "file", "type", "extrinsic"]
                )
                @test flagged(
                    check_csv(csv), 1,
                    "wrong type ($old was renamed to $new)"
                )
            end
        end
        # an unrecognized value that is not a retired one keeps the plain message
        csv = write_rows(
            joinpath(DATADIR, "wrong_type_plain.csv"), [["c", ART.video, "banana", "1"]];
            header = ["rectification_id", "file", "type", "extrinsic"]
        )
        @test flagged(check_csv(csv), 1, "wrong type")
    end
end
