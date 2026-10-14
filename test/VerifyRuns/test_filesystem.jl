@testset "filesystem" begin
    # A missing folder or file names what was looked for and where, joined to the data folder (#427):
    # nothing else in the report shows the value, since a failed check nulls its own field.
    data_folder = normpath(abspath(DATADIR))

    @testset "a missing path names the folder" begin
        df = check([runrow(path = "no_such_dir")])
        @test flagged(df, 1, "path must be an existing folder: $(joinpath(data_folder, "no_such_dir")) does not exist")
        @test !flagged(df, 1, "file must exist")    # the row's file is not also reported
    end

    @testset "a missing file names it and the folder it was looked for in" begin
        df = check([runrow(file = "no_such_file.mp4")])
        @test flagged(df, 1, "file must exist: no_such_file.mp4 is not in $data_folder — a")
    end

    @testset "a path naming the video itself says so (#33)" begin
        # The targeted message runs first and nulls :path, so the existence checks do not also fire.
        df = check([runrow(path = ART.a)])
        @test flagged(df, 1, "path must be the folder holding the video, not a file")
        @test !flagged(df, 1, "path must be an existing folder")
        @test !flagged(df, 1, "file must exist")
    end
end
