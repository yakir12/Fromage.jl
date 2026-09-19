@testset "variant catalogue" begin
    @test length(VARIANTS) == 32
    @test allunique(r.name for r in VARIANTS)
    @test first(VARIANTS).name == "baseline"

    # The spec's independent settings and full grid, with no two-term lens in the grid.
    singles = [r for r in VARIANTS if !occursin("_k1_", r.name)]
    @test count(r -> startswith(r.name, "sar_"), singles) == 5
    @test count(r -> startswith(r.name, "k1_"), singles) == 6
    grid = [r for r in VARIANTS if startswith(r.name, "sar_") && occursin("_k1_", r.name)]
    @test Set((Camera(r).sar, Camera(r).k[1]) for r in grid) ==
        Set((sar, k1) for sar in (1 // 2, 10 // 11, 16 // 15, 64 // 45, 2 // 1), k1 in (-0.05, -0.15, -0.3, 0.05))
    @test all(r -> Camera(r).k[2:3] == (0.0, 0.0) && r.radial_parameters == 1, grid)

    two_term = filter(r -> startswith(r.name, "k1_k2_"), VARIANTS)
    @test sort([r.radial_parameters for r in two_term]) == [1, 2]
    @test all(r -> Camera(r).k == (-0.25, 0.08, 0.0) && Camera(r).sar == 1, two_term)
    # The angles and frame identities are frozen even where detection will fail.
    baseline = board_poses(Camera(first(VARIANTS)))
    for rig in VARIANTS
        poses = board_poses(Camera(rig))
        @test [p.name for p in poses] == [p.name for p in baseline]
        @test all(p.board.e1 ≈ b.board.e1 && p.board.e2 ≈ b.board.e2 for (p, b) in zip(poses[1:23], baseline[1:23]))
    end

    @test [r.name for r in CRS.select_rigs(["sar_64_45", "baseline"])] == ["baseline", "sar_64_45"]
    mktempdir() do dir
        @test_throws ArgumentError simulate(; results_dir = joinpath(dir, "results"), cache_dir = joinpath(dir, "cache"), variants = ["baseline", "unknown"])
        @test isempty(readdir(dir))
    end
end

# Share the baseline acceptance's video cache, so this only renders two new cameras. Exercise the
# public entry point: the baseline still supplies the floor but must not leak into the report.
function test_named_subset(results_dir, cache_dir)
    return @testset "named subset through simulate" begin
        selected = ["sar_64_45", "k1_k2_fit2", "k1_k2_fit1"]
        report = redirect_stdout(devnull) do
            simulate(; results_dir, cache_dir, variants = selected)
        end
        @test unique(report.rig) == selected
        @test !any(==("rig"), report.quantity)
        for rung in ("builders", "csv")
            partial = report[(report.rig .== "sar_64_45") .& (report.rung .== rung), :]
            detected = partial[partial.quantity .== "detection", :]
            @test nrow(detected) == 29 # 28 frames and their total
            @test only(detected[detected.split .== "flat", :value]) == 0
            intrinsics = partial[(partial.quantity .== "intrinsics") .& coalesce.(partial.builder .== "from_checkerboard", false), :]
            @test all(==("ok"), intrinsics.status)
            @test all(!ismissing, intrinsics.value)
            maps = partial[(partial.quantity .== "map") .& (partial.section .== "fromage"), :]
            @test nrow(maps) == 24
            @test all(ismissing, maps.value)
            @test all(!=("ok"), maps.status)

            k2(name) = only(
                r.value for r in eachrow(report) if r.rig == name && r.rung == rung &&
                    r.section == "fromage" && isequal(r.builder, "from_checkerboard") &&
                    r.quantity == "intrinsics" && r.split == "k2" && r.statistic == "fitted"
            )
            @test k2("k1_k2_fit2") ≈ 0.08 atol = 0.02
            @test k2("k1_k2_fit1") == 0
        end
    end
end

@testset "two-term lens fitting order without a flat-board detection" begin
    cam = Camera(only(filter(r -> r.name == "k1_k2_fit2", VARIANTS)))
    poses = board_poses(cam)
    calibration = [CRS.fromage_corners(cam, p.board) for p in poses[1:(end - 1)]]
    g = CRS.Gauge(cam)
    fits = CRS.builder_fits(cam, g, "no video is read", calibration, CRS.Failure("not detected"), 2)
    @test fits.from_checkerboard.model.k[1] ≈ -0.25 atol = 1.0e-4
    @test fits.from_checkerboard.model.k[2] ≈ 0.08 atol = 1.0e-4
    @test fits.from_checkerboard.rect == CRS.Failure("not detected")
    underfit = CRS.builder_fits(cam, g, "no video is read", calibration, CRS.Failure("not detected"), 1)
    @test underfit.from_checkerboard.model.k[2] == 0

    # A gateway error must not erase the intrinsics already available from calibration frames.
    # This empty video provokes a real gateway failure without relying on a particular detector.
    mktempdir() do dir
        file = touch(joinpath(dir, "empty.mp4"))
        csv = redirect_stdout(devnull) do
            CRS.csv_fits(cam, g, poses, file, [calibration; [CRS.Failure("not detected")]], dir, 2)
        end
        @test csv.from_checkerboard.model.k[2] ≈ 0.08 atol = 1.0e-4
        @test startswith(csv.from_checkerboard.rect.status, "threw: ")
        @test csv.from_extrinsic.rect == csv.from_checkerboard.rect
    end
end
