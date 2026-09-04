@testset "filesystem" begin
    @testset "path does not exist" begin
        df = check([checkerboardrow(path = "no_such_dir")])
        @test flagged(df, 1, "path does not exist")
    end

    @testset "file does not exist" begin
        df = check([checkerboardrow(file = "no_such_file.mp4")])
        @test flagged(df, 1, "file does not exist")
    end

    @testset "a path naming the video itself says so (#33)" begin
        # The targeted message runs first and nulls :path, so the existence check does not also
        # fire with the misleading "path does not exist".
        df = check([checkerboardrow(path = ART.board)])
        @test flagged(df, 1, "path is a file, not a folder")
        @test !flagged(df, 1, "path does not exist")
    end

    @testset "matlab_file does not exist" begin
        # the .mat path is resolved/checked against path just like the source video `file`
        df = check([matlabrow(matlab_file = "no_such_file.mat")])
        @test flagged(df, 1, "matlab_file does not exist")
    end
end
