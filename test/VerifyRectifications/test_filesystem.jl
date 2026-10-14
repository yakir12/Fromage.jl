@testset "filesystem" begin
    # A missing folder or file names what was looked for and where, joined to the data folder (#427).
    data_folder = normpath(abspath(DATADIR))

    @testset "a missing path names the folder" begin
        df = check([checkerboardrow(path = "no_such_dir")])
        @test flagged(df, 1, "path must be an existing folder: $(joinpath(data_folder, "no_such_dir")) does not exist")
        @test !flagged(df, 1, "file must exist")
    end

    @testset "a missing file names it and the folder it was looked for in" begin
        df = check([checkerboardrow(file = "no_such_file.mp4")])
        @test flagged(df, 1, "file must exist: no_such_file.mp4 is not in $data_folder — a")
    end

    @testset "a path naming the video itself says so (#33)" begin
        # The targeted message runs first and nulls :path, so the existence checks do not also fire.
        df = check([checkerboardrow(path = ART.board)])
        @test flagged(df, 1, "path must be the folder holding the video, not a file")
        @test !flagged(df, 1, "path must be an existing folder")
        @test !flagged(df, 1, "file must exist")
    end

    @testset "a missing matlab_file names it and the folder it was looked for in" begin
        # the .mat path is resolved/checked against path just like the source video `file`
        df = check([matlabrow(matlab_file = "no_such_file.mat")])
        @test flagged(df, 1, "matlab_file must exist: no_such_file.mat is not in $data_folder — a")
    end
end
