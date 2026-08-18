@testset "filesystem" begin
    @testset "path does not exist" begin
        @test flagged(check("fs_dir.csv", [runrow(path = "no_such_dir")]), 1, "path does not exist")
    end

    @testset "file does not exist" begin
        @test flagged(check("fs_file.csv", [runrow(file = "no_such_file.mp4")]), 1, "file does not exist")
    end

    @testset "a path naming the video itself says so (#33)" begin
        # The targeted message runs first and nulls :path, so the existence check does not also
        # fire with the misleading "path does not exist".
        df = check("fs_pathisfile.csv", [runrow(path = ART.a)])
        @test flagged(df, 1, "path is a file, not a folder")
        @test !flagged(df, 1, "path does not exist")
    end
end
