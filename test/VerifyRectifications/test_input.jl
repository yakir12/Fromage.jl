@testset "input validation" begin
    # These error unconditionally (before the strict block), so they throw regardless.

    @testset "missing csv file" begin
        @test_throws "missing" VRect.load_rectifications(DATADIR, joinpath(DATADIR, "does_not_exist.csv"))
    end

    @testset "empty csv file" begin
        csv = write_rows(joinpath(DATADIR, "empty.csv"), [])   # header only, no data rows
        @test_throws "csv file is empty" VRect.load_rectifications(DATADIR, csv)
    end

    @testset "unrecognized column" begin
        csv = write_rows(joinpath(DATADIR, "badcol.csv"), [["x", "y"]]; header = ["calibration_id", "foo"])
        @test_throws "unrecognized column" VRect.load_rectifications(DATADIR, csv)
    end

    # A retired column is the one unrecognized name a user cannot debug from the generic message:
    # their file was correct when they wrote it. checker_size split into checker_width (video) and
    # tag_cell_width (apriltag) in v0.1.58, so the error has to name both.
    @testset "a renamed column says where it went" begin
        csv = write_rows(joinpath(DATADIR, "renamedcol.csv"), [["c", "4"]];
                         header = ["calibration_id", "checker_size"])
        @test_throws "checker_size was renamed to checker_width" VRect.load_rectifications(DATADIR, csv)
        @test_throws "tag_cell_width" VRect.load_rectifications(DATADIR, csv)
    end

    # The v0.2.23 vocabulary migration. Each old name is rejected at the file level, before any row
    # parses, and has to name its replacement — the user's file was correct when they wrote it.
    @testset "the v0.2.23 renamed columns say where they went" begin
        for (old, new) in ((:scale, "pixel_width"), (:start, "intrinsic_start"), (:stop, "intrinsic_stop"))
            @testset "$old → $new" begin
                csv = write_rows(joinpath(DATADIR, "renamed_$old.csv"), [["c", "1"]];
                                 header = ["calibration_id", string(old)])
                @test_throws "unrecognized column" VRect.load_rectifications(DATADIR, csv)
                @test_throws "$old was renamed to $new" VRect.load_rectifications(DATADIR, csv)
            end
        end
        # calibs.csv's `scale` and runs.csv's `scale` went to different places; this file must never
        # be pointed at the other one's replacement.
        csv = write_rows(joinpath(DATADIR, "renamed_scale_only.csv"), [["c", "1"]];
                         header = ["calibration_id", "scale"])
        err = try VRect.load_rectifications(DATADIR, csv) catch e; sprint(showerror, e) end
        @test !occursin("downscale", err)
    end

    # A retired `type` VALUE cannot be caught by RENAMED_COLUMNS: the column name is still valid, so
    # `read_rows` passes it through and only the row parser sees it. Without RENAMED_TYPES the
    # commonest legacy value produced a bare "wrong type".
    @testset "a renamed type value says where it went" begin
        for (old, new) in (("video", "checkerboard"), ("only_scale", "uniform"))
            @testset "type = $old" begin
                csv = write_rows(joinpath(DATADIR, "renamed_type_$old.csv"), [["c", ART.video, old, "1"]];
                                 header = ["calibration_id", "file", "type", "extrinsic"])
                @test flagged(VRect.check_rectifications(DATADIR, csv), 1,
                              "wrong type ($old was renamed to $new)")
            end
        end
        # an unrecognized value that is not a retired one keeps the plain message
        csv = write_rows(joinpath(DATADIR, "wrong_type_plain.csv"), [["c", ART.video, "banana", "1"]];
                         header = ["calibration_id", "file", "type", "extrinsic"])
        @test flagged(VRect.check_rectifications(DATADIR, csv), 1, "wrong type")
    end
end
