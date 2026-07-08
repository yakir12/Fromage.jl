@testset "input validation" begin
    # These error unconditionally (before the strict block), so they throw regardless.

    @testset "missing csv file" begin
        @test_throws "missing" VC.load_calibrations(DATADIR, joinpath(DATADIR, "does_not_exist.csv"))
    end

    @testset "empty csv file" begin
        csv = write_csv(joinpath(DATADIR, "empty.csv"), [])   # header only, no data rows
        @test_throws "csv file is empty" VC.load_calibrations(DATADIR, csv)
    end

    @testset "unrecognized column" begin
        csv = write_csv(joinpath(DATADIR, "badcol.csv"), [["x", "y"]]; header = ["calibration_id", "foo"])
        @test_throws "unrecognized column" VC.load_calibrations(DATADIR, csv)
    end
end
