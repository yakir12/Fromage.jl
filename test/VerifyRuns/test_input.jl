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
