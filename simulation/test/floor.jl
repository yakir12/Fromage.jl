@testset "replicate poses" begin
    cam = Camera(; BASELINE_CAMERA...)
    poses = board_poses(cam)
    replicates = [CRS.jittered(cam, poses, seed) for seed in 1:10]
    @test length(CRS.REPLICATES) == 10 && allunique(CRS.REPLICATES)
    @test all(length(ps) == 28 for ps in replicates)
    @test first(replicates) == CRS.jittered(cam, poses, 1)
    @test allunique([ps[end].board.center for ps in replicates])
    for ps in replicates, (original, shifted) in zip(poses, ps)
        a, b = original.board, shifted.board
        @test original.name == shifted.name
        @test a.e1 == b.e1 && a.e2 == b.e2
        offset = b.center - a.center
        # The camera's third coordinate is depth; its transverse pixel pitch is depth / f.
        depth = (cam.rotation * (a.center - cam.position))[3]
        half_pixel = depth / (2cam.f)
        @test 0 < norm(offset)
        @test abs(offset ⋅ a.e1) ≤ half_pixel && abs(offset ⋅ a.e2) ≤ half_pixel
        @test abs(offset ⋅ (a.e1 × a.e2)) < 1.0e-14
    end
    @test poses == board_poses(cam)
    # The cache must distinguish replicates, yet repeat the same key for the same seed.
    boards(ps) = [p.board for p in ps]
    keys = [CRS.cache_key(cam, boards(ps), CRS.SUPERSAMPLING, RENDERER_VERSION) for ps in replicates]
    @test allunique(keys)
    @test first(keys) == CRS.cache_key(cam, boards(CRS.jittered(cam, poses, 1)), CRS.SUPERSAMPLING, RENDERER_VERSION)
end
