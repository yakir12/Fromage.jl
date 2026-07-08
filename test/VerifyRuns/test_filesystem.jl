@testset "filesystem" begin
    @testset "path does not exist" begin
        @test flagged(check("fs_dir.csv", [runrow(path = "no_such_dir")]), 1, "path does not exist")
    end

    @testset "file does not exist" begin
        @test flagged(check("fs_file.csv", [runrow(file = "no_such_file.mp4")]), 1, "file does not exist")
    end
end
