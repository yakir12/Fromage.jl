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
end
