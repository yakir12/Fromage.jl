using CalibrationRigSimulation: CalibrationRigSimulation, BASELINE_CAMERA, Board, Camera, RENDERER_VERSION,
    Rig, VARIANTS, area_centroid, board_poses, cached_video, corner_projections, detect_dots, encode,
    inner_corners, project, ray, render, simulate, trace
using CSV: CSV
using Fromage: Fromage
using DataFrames: DataFrame, nrow
using LinearAlgebra: norm, normalize, ×, ⋅
using OpenCV: OpenCV
using StaticArrays: SVector
using Test: @test, @test_throws, @testset
using VideoIO: VideoIO

const CRS = CalibrationRigSimulation

# the baseline rig's camera (#289, #291), at any lens and `sar`
camera(k, sar) = Camera(;
    position = SVector(1.5, 0.0, 1.5), target = SVector(0.0, 0.0, 0.0),
    f = 900.0, principal_point = SVector(971.8, 531.7), k, sar,
)

# the `k1` variants (#289), the canonical no distortion, a `k1 + k2` lens, and a lens with `k3`,
# which places k3 in OpenCV's `(k1, k2, p1, p2, k3)`. The last two are this test's own; #304 fixes
# the `k1 + k2` lens the variants use.
const LENSES = [
    (0.0, 0.0, 0.0),
    (-0.05, 0.0, 0.0), (-0.15, 0.0, 0.0), (-0.3, 0.0, 0.0), (0.05, 0.0, 0.0),
    (-0.25, 0.08, 0.0),
    (-0.2, 0.05, -0.01),
]
const SARS = (1 // 1, 1 // 2, 2 // 1)

# the arena floor and a board-height layer above it: the space the rig's objects occupy
const WORLD = [SVector(x, y, z) for x in -1.2:0.1:1.2, y in -1.2:0.1:1.2, z in (0.0, 0.3)]

# OpenCV's Mat layout for a matrix M: (channels, cols, rows)
cvmat(M::AbstractMatrix) = reshape(permutedims(M), 1, size(M, 2), size(M, 1))
cvvec(v) = reshape(collect(Float64, v), length(v), 1, 1)

# stored (row, col) of each world point, by OpenCV's projectPoints with the camera's own parameters
function opencv_project(cam::Camera, Ps)
    sar = float(cam.sar)
    K = [
        cam.f / sar 0 cam.principal_point[1] / sar
        0 cam.f cam.principal_point[2]
        0 0 1
    ]
    R = Matrix(cam.rotation)
    rvec = OpenCV.Rodrigues(cvmat(R))[1]
    tvec = cvvec(-R * cam.position)
    obj = reshape(reduce(hcat, Ps), 3, 1, length(Ps))
    dist = reshape([cam.k[1], cam.k[2], 0.0, 0.0, cam.k[3]], 1, 1, 5)
    uv = Array(OpenCV.projectPoints(obj, Array(rvec), tvec, cvmat(K), dist)[1])
    return [SVector(uv[2, 1, i], uv[1, 1, i]) for i in axes(uv, 3)]
end

@testset "CalibrationRigSimulation" begin
    include("verdicts.jl")
    include("floor.jl")

    @testset "camera model vs the OpenCV oracle" begin
        for k in LENSES, sar in SARS
            cam = camera(k, sar)
            Ps = filter(P -> project(cam, P) !== nothing, vec(WORLD))
            # the fold rejects part of the grid for the strong k1 only
            @test length(Ps) ≥ (k[1] == -0.3 ? 0.5 : 1) * length(WORLD)
            ours = [project(cam, P) for P in Ps]
            theirs = opencv_project(cam, Ps)
            @test maximum(maximum(abs, a - b) for (a, b) in zip(ours, theirs)) < 1.0e-6
        end
    end

    @testset "stored frame and fixed field of view" begin
        @test (camera(LENSES[1], 1 // 1).width, camera(LENSES[1], 1 // 1).height) == (1920, 1080)
        @test (camera(LENSES[1], 2 // 1).width, camera(LENSES[1], 2 // 1).height) == (960, 1080)
        @test (camera(LENSES[1], 1 // 2).width, camera(LENSES[1], 1 // 2).height) == (1920, 540)
        shown(cam, P) = (p = project(cam, P); SVector(p[2] * cam.sar, p[1]))
        for k in LENSES, P in WORLD
            project(camera(k, 1 // 1), P) === nothing && continue
            at_sar1 = shown(camera(k, 1 // 1), P)
            @test shown(camera(k, 2 // 1), P) ≈ at_sar1 atol = 1.0e-9
            @test shown(camera(k, 1 // 2), P) ≈ at_sar1 / 2 atol = 1.0e-9
        end
    end

    @testset "arguments" begin
        # a float sar once became a rational whose terms overflowed against an integer pixel
        @test_throws TypeError camera(LENSES[1], 0.9)
        @test ray(camera(LENSES[1], 9 // 10), SVector(500, 1919)) ≈ ray(camera(LENSES[1], 9 // 10), SVector(500.0, 1919.0))
        @test_throws ArgumentError camera((NaN, 0.0, 0.0), 1 // 1)
        @test_throws ArgumentError Camera(;
            position = SVector(1.0, 0.0, 1.0), target = SVector(1.0, 0.0, 1.0),
            f = 900.0, principal_point = SVector(971.8, 531.7), k = LENSES[1], sar = 1,
        )
        @test_throws ArgumentError Camera(;
            position = SVector(0.0, 0.0, 1.0), target = SVector(0.0, 0.0, 0.0),
            f = 900.0, principal_point = SVector(971.8, 531.7), k = LENSES[1], sar = 1,
        )
    end

    @testset "inverse" begin
        for k in LENSES, sar in SARS
            cam = camera(k, sar)
            # world → pixel → ray recovers the direction to the point
            for P in WORLD
                p = project(cam, P)
                p === nothing && continue
                @test ray(cam, p) ≈ normalize(P - cam.position) atol = 1.0e-9
            end
            # pixel → ray → pixel, over the whole stored frame
            for row in range(0, cam.height - 1, 13), col in range(0, cam.width - 1, 13)
                d = ray(cam, SVector(row, col))
                d === nothing && continue
                @test project(cam, cam.position + d) ≈ SVector(row, col) atol = 1.0e-6
            end
        end
    end

    @testset "fold guard" begin
        @test CRS.fold_radius((0.0, 0.0, 0.0)) == Inf
        @test CRS.fold_radius((0.05, 0.0, 0.0)) == Inf
        @test CRS.fold_radius((-0.25, 0.08, 0.0)) == Inf
        # with k2 = k3 = 0 the fold is at r² = −1 / (3 k1)
        for k1 in (-0.05, -0.15, -0.3)
            @test CRS.fold_radius((k1, 0.0, 0.0)) ≈ sqrt(-1 / 3k1) rtol = 1.0e-12
        end
        # with k3 the fold is the first root of the slope, inside MAX_RADIUS
        k = (-0.2, 0.05, -0.01)
        fold3 = CRS.fold_radius(k)
        @test 1 < fold3 < CRS.MAX_RADIUS
        @test abs(CRS.distorted_slope(k, fold3)) < 1.0e-12
        @test all(r -> CRS.distorted_slope(k, r) > 0, range(0, 0.999fold3, 1000))

        cam = camera((-0.3, 0.0, 0.0), 1 // 1)
        fold = sqrt(1 / 0.9)
        @test cam.max_radius ≈ fold
        # a world point at undistorted radius r along the camera's x axis
        along(r) = cam.position + cam.rotation' * SVector(r, 0.0, 1.0)
        @test project(cam, along(0.99fold)) !== nothing
        @test project(cam, along(1.01fold)) === nothing
        # a pixel at distorted radius rd along the image's x axis; the fold's image is at g(fold)
        gfold = fold * (1 - 0.3fold^2)
        pixel(rd) = SVector(cam.principal_point[2], cam.principal_point[1] + cam.f * rd)
        @test ray(cam, pixel(0.99gfold)) !== nothing
        @test ray(cam, pixel(1.01gfold)) === nothing
        # past the fold, a strong negative k1 folds back: two radii share an image, and only the
        # one inside the fold is the model's
        r_out = 1.3fold
        rd = r_out * (1 - 0.3r_out^2)
        @test 0 < rd < gfold
        d = ray(cam, pixel(rd))
        p = cam.rotation * d
        @test hypot(p[1], p[2]) / p[3] < fold
        # the corners of this camera's frame lie past the fold, and have no ray
        @test ray(cam, SVector(0.0, 0.0)) === nothing
    end

    # the baseline rig, and its flat frame rendered once for the renderer and dot detector testsets
    cam = Camera(; BASELINE_CAMERA...)
    poses = board_poses(cam)
    flat = render(cam, last(poses).board)

    @testset "poses" begin
        @test length(poses) == 28
        @test count(p -> startswith(p.name, "waved about vertical"), poses) == 13
        @test count(p -> startswith(p.name, "waved about horizontal"), poses) == 10
        @test count(p -> startswith(p.name, "corner"), poses) == 4
        @test last(poses).name == "flat"
        @test allunique(p.name for p in poses)
        @test last(poses).board.center == SVector(0.0, 0.0, 0.0)
        @test last(poses).board.e1 == SVector(0.0, 1.0, 0.0)
        # the whole board, its white margin included, lies inside the stored frame
        inside(p) = p !== nothing && 0 ≤ p[1] ≤ cam.height - 1 && 0 ≤ p[2] ≤ cam.width - 1
        for (; board) in poses
            @test all(inside(project(cam, P)) for P in CRS.outline(board))
            @test size(inner_corners(board)) == (10, 7)
            @test corner_projections(cam, board) == project.(Ref(cam), inner_corners(board))
        end
        # the corners are indexed along e1, then e2, from the black first square's inner corner
        board = last(poses).board
        @test inner_corners(board)[1, 1] ≈ board.center + (0.04 - 0.22) * board.e1 + (0.04 - 0.16) * board.e2
        @test inner_corners(board)[10, 7] ≈ board.center + (0.22 - 0.04) * board.e1 + (0.16 - 0.04) * board.e2
        # a board behind the camera has no projection
        @test_throws ArgumentError corner_projections(cam, CRS.Board(cam.position + SVector(1.0, 0.0, 0.0), SVector(0.0, 1.0, 0.0), SVector(1.0, 0.0, 0.0)))
        # every waved and corner pose is fitted as far as it goes: its edge sits on the pose margin
        margin = CRS.POSE_MARGIN * cam.height
        for (; board) in poses[1:(end - 1)]
            ps = [project(cam, P) for P in CRS.outline(board)]
            gap = minimum(min(p[1], cam.height - 1 - p[1], p[2], cam.width - 1 - p[2]) for p in ps)
            @test gap ≈ margin atol = 0.5
        end
        # a corner pose is held where its board, untilted on the optical axis, would span ⅕ of the
        # frame's width, and sits in its own corner
        for (; name, board) in filter(p -> startswith(p.name, "corner"), poses)
            @test norm(board.center - cam.position) ≈ BASELINE_CAMERA.f * 0.52 / (1920 * CRS.CORNER_SPAN)
            p = project(cam, board.center)
            @test (p[1] < cam.principal_point[2]) == occursin("top", name)
            @test (p[2] < cam.principal_point[1]) == occursin("left", name)
        end
        # the waved poses face the camera straight on at 0°, and turn by the frozen angles
        facing(board) = rad2deg(acos(clamp(-CRS.forward(cam)' * (board.e2 × board.e1), -1, 1)))
        for (; name, board) in filter(p -> startswith(p.name, "waved"), poses)
            @test facing(board) ≈ abs(parse(Int, match(r"(-?\d+)°", name)[1])) atol = 1.0e-9
        end
    end

    @testset "surface precedence" begin
        ground(X, Y) = CRS.ground_surface(SVector(X, Y))
        # the arena's rim, along two directions
        for θ in (0.0, 1.0)
            @test ground(0.999cos(θ), 0.999sin(θ)) == CRS.ARENA
            @test ground(1.001cos(θ), 1.001sin(θ)) == CRS.FLOOR
        end
        # a dot is painted over the arena, at both dots
        for Y in (0.5, -0.5)
            @test ground(0.0, Y) == CRS.DOT
            @test ground(0.0, Y + 0.019) == CRS.DOT
            @test ground(0.0, Y + 0.021) == CRS.ARENA
        end
        # a ray from the camera to a world point, with and without a board
        towards(board, P) = trace(board, cam.position, normalize(P - cam.position))
        board = last(poses).board
        @test towards(nothing, SVector(0.0, 0.0, 0.0)).surface == CRS.ARENA
        @test towards(nothing, SVector(0.0, 0.5, 0.0)).surface == CRS.DOT
        @test towards(nothing, SVector(1.2, 0.0, 0.0)).surface == CRS.FLOOR
        # the flat board lies on the arena, coplanar with it, and is drawn over it
        @test towards(board, SVector(0.01, 0.01, 0.0)).surface == CRS.BOARD
        # inside the white margin (the board is 52 cm long, along y) and just past it
        @test towards(board, SVector(0.0, 0.25, 0.0)) == (surface = CRS.BOARD, reflectance = 1.0)
        @test towards(board, SVector(0.0, 0.27, 0.0)).surface == CRS.ARENA
        # the first square is black, its neighbour along the long axis white
        first_square = board.center - 0.2board.e1 - 0.14board.e2
        @test towards(board, first_square) == (surface = CRS.BOARD, reflectance = 0.0)
        @test towards(board, first_square + 0.04board.e1) == (surface = CRS.BOARD, reflectance = 1.0)
        # a board held above the arena hides the ground behind it, and not the ground beside it
        for (; board) in poses[1:(end - 1)]
            @test towards(board, board.center).surface == CRS.BOARD
            @test towards(board, board.center + 0.3board.e1 + 0.3board.e2).surface != CRS.BOARD
        end
        # a ray that leaves the ground plane meets nothing
        @test trace(nothing, cam.position, SVector(0.0, 0.0, 1.0)).surface == CRS.SKY
        # the board's reflectance depends on where it is hit, so it has no single value
        @test_throws ArgumentError CRS.reflectance(CRS.BOARD)
        # a board's axes must be orthonormal
        @test_throws ArgumentError Board(SVector(0.0, 0.0, 0.0), SVector(0.0, 1.0, 0.0), SVector(0.5, 0.0, 0.0))
        @test_throws ArgumentError Board(SVector(0.0, 0.0, 0.0), SVector(0.0, 1.0, 0.0), SVector(0.0, 1.0, 0.0))
    end

    @testset "renderer" begin
        @test size(flat) == (cam.height, cam.width)
        pixel(P) = (p = round.(Int, project(cam, P)); flat[p[1] + 1, p[2] + 1])
        @test pixel(SVector(0.6, 0.6, 0.0)) == 0xff  # arena
        @test pixel(SVector(1.1, 0.0, 0.0)) == 0x80  # floor, mid-grey
        @test pixel(SVector(0.0, 0.5, 0.0)) == 0x00  # a dot's centre
        @test pixel(SVector(0.0, 0.25, 0.0)) == 0xff  # the board's white margin
        # a pixel on the edge between a black and a white square is grey
        board = last(poses).board
        @test 0x10 < pixel(board.center - 0.18board.e1 - 0.14board.e2) < 0xf0
        # each pixel is the mean over its explicit samples, so one sample per pixel leaves the
        # frame's mean where it was but moves the pixels on edges
        coarse = render(cam, board; samples = 1)
        @test abs(sum(Int, flat) - sum(Int, coarse)) / length(flat) < 0.5
        @test count(flat .!= coarse) > 1000
    end

    @testset "dot detector" begin
        found = detect_dots(flat)
        # the flat board's black squares touch each other and its margin, so none is a dot
        @test length(found) == 2
        for c in CRS.DOT_CENTRES
            truth = area_centroid(cam, c)
            # the perspective bias the area centroid corrects (#292)
            @test 0.02 < norm(truth - project(cam, SVector(c[1], c[2], 0.0))) < 0.08
            @test minimum(norm(d - truth) for d in found) < 0.05
        end
    end

    # the stored footprint is rectangular in display space at `sar ≠ 1`: the dots still land on their
    # area centroids, and the poses still fit, at the narrowed width and at the halved height
    @testset "sar $sar" for sar in (2 // 1, 1 // 2)
        cam = Camera(; BASELINE_CAMERA..., sar)
        poses = board_poses(cam)
        @test length(poses) == 28
        inside(p) = p !== nothing && 0 ≤ p[1] ≤ cam.height - 1 && 0 ≤ p[2] ≤ cam.width - 1
        @test all(inside(project(cam, P)) for (; board) in poses for P in CRS.outline(board))
        found = detect_dots(render(cam, last(poses).board))
        @test length(found) == 2
        for c in CRS.DOT_CENTRES
            @test minimum(norm(d - area_centroid(cam, c)) for d in found) < 0.05
        end
    end

    # render → encode → decode through the frame reader Fromage's builders use returns the same
    # pixels, and every sar reader Fromage has (both gateways' ffprobe, the tracker's VideoIO) sees
    # the sar (#293). 4×4 sampling keeps it quick and still greys the edges; the ramp holds every
    # 8-bit level, so a range conversion (#293's `yuv420p` route was off by one level) cannot hide.
    @testset "lossless round trip at sar $sar" for sar in (1 // 2, 10 // 11, 1 // 1, 16 // 15, 64 // 45, 2 // 1)
        # `local`: an assignment in a testset's loop would otherwise rebind the enclosing testset's `cam`
        local cam = Camera(; BASELINE_CAMERA..., sar)
        ramp = [UInt8((i + j) % 256) for i in 1:cam.height, j in 1:cam.width]
        frames = [render(cam, last(board_poses(cam)).board; samples = 4), ramp]
        @test length(unique(first(frames))) > 3
        mktempdir() do dir
            file = encode(joinpath(dir, "board.mp4"), frames, sar)
            for (k, frame) in enumerate(frames)
                # frame k - 1 is at t = k - 1 s
                @test Fromage.Rectifications._frame_at(file, k - 1, missing, cam.width, cam.height) == frame
            end
            probed = Fromage.VerifyRectifications.probe_video(file)
            @test (probed.width, probed.height, probed.aspect) == (cam.width, cam.height, float(sar))
            @test Fromage.VerifyRuns.probe_video(file).sar == sar
            @test VideoIO.openvideo(VideoIO.aspect_ratio, file) == sar
        end
    end

    @testset "cache" begin
        # one unsampled frame of the rig with no board keeps each render cheap
        local cam = Camera(; BASELINE_CAMERA...)
        mktempdir() do cache_dir
            request(cam) = cached_video(cache_dir, cam, [nothing]; samples = 1)
            file = request(cam)
            @test isfile(file) && dirname(file) == cache_dir
            @test Fromage.Rectifications._frame_at(file, 0, missing, cam.width, cam.height) == render(cam, nothing; samples = 1)
            # a second request for the same rig finds the video and re-renders nothing
            before = stat(file)
            @test request(Camera(; BASELINE_CAMERA...)) == file
            @test (stat(file).inode, stat(file).mtime) == (before.inode, before.mtime)
            @test readdir(cache_dir) == [basename(file)]
            # changing one setting, the sampling, or the boards is a different video
            other = request(Camera(; BASELINE_CAMERA..., k = (-0.05, 0.0, 0.0)))
            @test other != file && isfile(other)
            @test cached_video(cache_dir, cam, [nothing]; samples = 2) ∉ (file, other)
            @test cached_video(cache_dir, cam, [nothing, nothing]; samples = 1) ∉ (file, other)
            @test length(readdir(cache_dir)) == 4
            # and so does bumping the renderer's version: the key moves, so the video is re-rendered
            key(version) = CRS.cache_key(cam, [nothing], 1, version)
            @test basename(file) == key(RENDERER_VERSION) * ".mp4"
            @test key(RENDERER_VERSION + 1) != key(RENDERER_VERSION)
            # the same boards are the same key whatever the vector's element type, and whatever the
            # requesting session has imported: `repr` once printed both into the key
            board = last(board_poses(cam)).board
            @test CRS.cache_key(cam, [board], 1, 1) == CRS.cache_key(cam, Union{Board, Nothing}[board], 1, 1)
            elsewhere = """import CalibrationRigSimulation as C
            print(C.cache_key(C.Camera(; C.BASELINE_CAMERA...), [nothing], 1, $RENDERER_VERSION))"""
            @test readchomp(`$(Base.julia_cmd()) --project=$(Base.active_project()) --startup-file=no -e $elsewhere`) == key(RENDERER_VERSION)
        end
    end

    @testset "encoding failures" begin
        @test_throws ArgumentError encode(joinpath(mktempdir(), "empty.mp4"), Matrix{UInt8}[], 1 // 1)
        @test_throws ArgumentError encode(joinpath(mktempdir(), "ragged.mp4"), [zeros(UInt8, 4, 4), zeros(UInt8, 4, 6)], 1 // 1)
        # ffmpeg's own reason reaches the exception, rather than only the terminal
        @test_throws r"^ffmpeg could not encode .+ \(exit \d+\): \S" encode(joinpath(mktempdir(), "missing", "x.mp4"), [zeros(UInt8, 4, 4)], 1 // 1)
    end

    # `center`/`north` snapped to whole display pixels, and the truth they define (#294)
    @testset "gauge" begin
        local cam = Camera(; BASELINE_CAMERA...)
        g = CRS.Gauge(cam)
        shown(P) = CRS.display_point(cam, project(cam, P))
        @test g.center == round.(shown(SVector(0.0, 0.0, 0.0))) && g.north == round.(shown(SVector(0.0, 0.5, 0.0)))
        # the snapped origin is within a pixel's footprint of the arena's middle, and north within a
        # pixel's turn of +Y
        @test norm(g.origin) < 0.002
        @test abs(g.y[1]) < 0.002 && g.y[2] > 0
        @test g.x ⋅ g.y ≈ 0 atol = 1.0e-12
        # Fromage's real (y, x) is (−Y, X) in the gauge's frame (#290), here in mm
        @test CRS.truth_mm(g, g.origin) == SVector(0.0, 0.0)
        @test CRS.truth_mm(g, g.origin + 0.1g.y) ≈ SVector(-100.0, 0.0)
        @test CRS.truth_mm(g, g.origin + 0.1g.x) ≈ SVector(0.0, 100.0)
        # a map that is the truth scores zero everywhere
        exact(p) = CRS.truth_mm(g, CRS.ground_point(cam, p)) / CRS.MM_PER_REAL
        errors = CRS.map_errors(exact, cam, g)
        @test first.(errors) == ("arena", "on board", "off board", "Procrustes")
        @test all(maximum(e) < 1.0e-9 for (_, e) in errors)
        @test length(last(errors[1])) == length(last(errors[2])) + length(last(errors[3])) == length(CRS.ARENA_GRID)
        # the flat board's footprint is 52 cm along Y and 40 cm along X
        @test CRS.on_flat_board(SVector(0.19, 0.25)) && !CRS.on_flat_board(SVector(0.21, 0.0)) && !CRS.on_flat_board(SVector(0.0, 0.27))
    end

    @testset "Procrustes" begin
        A = [SVector(cos(t), sin(2t)) for t in 0:0.3:6]
        R = [cos(0.4) -sin(0.4); sin(0.4) cos(0.4)]
        @test maximum(CRS.procrustes(A, [R * a + SVector(3.0, -1.0) for a in A])) < 1.0e-12
        # a mirror is a shape error, not a gauge error
        @test maximum(CRS.procrustes(A, [SVector(-a[1], a[2]) for a in A])) > 0.1
    end

    # the analytic projections in Fromage's order are what its detector finds, index for index
    @testset "Fromage's corner order" begin
        local cam = Camera(; BASELINE_CAMERA...)
        for (; board) in board_poses(cam)[[1, 7, 24, 28]]
            mktempdir() do dir
                file = encode(joinpath(dir, "board.mp4"), [render(cam, board; samples = 4)], cam.sar)
                found = Fromage.Rectifications.get_corners(file, 0.0, missing, cam.width, cam.height, CRS.N_CORNERS)
                truth = CRS.fromage_corners(cam, board)
                @test maximum(norm, CRS.corner_errors(found, truth)) < 0.5
                # a board found half a turn round is the same grid
                @test CRS.corner_errors(reverse(found), truth) ≈ reverse(CRS.corner_errors(found, truth))
            end
        end
    end

    # the acceptance of #301: exact corners through Fromage's fit reproduce the truth's map
    @testset "analytic control" begin
        local cam = Camera(; BASELINE_CAMERA...)
        g = CRS.Gauge(cam)
        fit = CRS.analytic_fit(cam, g, [CRS.fromage_corners(cam, p.board) for p in board_poses(cam)], CRS.RADIAL_PARAMETERS)
        arena = CRS.summarize(last(first(CRS.map_errors(fit.rect.image2real, cam, g))))
        @test arena.RMS ≈ 0.003 atol = 0.002
        @test arena.RMS < CRS.CONTROL_TOLERANCE
        @test fit.model.frow ≈ BASELINE_CAMERA.f rtol = 1.0e-5
    end

    # a rig whose flat board goes undetected reaches no map, and still reports the intrinsics of its
    # calibration frames (#294); every failure keeps a quantity's rows, so each rig reports the same rows
    @testset "failures keep their rows" begin
        local cam = Camera(; BASELINE_CAMERA...)
        g = CRS.Gauge(cam)
        calibration = [CRS.fromage_corners(cam, p.board) for p in board_poses(cam)[1:(end - 1)]]
        fits = CRS.builder_fits(cam, g, "no video is read", calibration, CRS.Failure("not detected"))
        @test fits.from_checkerboard.rect == fits.from_extrinsic.rect == fits.from_extrinsic.model == CRS.Failure("not detected")
        @test fits.from_checkerboard.model.frow ≈ BASELINE_CAMERA.f rtol = 1.0e-4
        ctx = (; rig = "r", rung = "builders", builder = "from_checkerboard", section = "fromage")
        failed = CRS.fit_rows(ctx, cam, g, fits.from_checkerboard)
        @test all(r.status == "ok" for r in failed if r.quantity == "intrinsics")
        @test all(r.status == "not detected" && ismissing(r.value) for r in failed if r.quantity == "map")
        exact = CRS.fit_rows(ctx, cam, g, CRS.analytic_fit(cam, g, [CRS.fromage_corners(cam, p.board) for p in board_poses(cam)], 1))
        layout(rows) = [(r.quantity, r.split, r.statistic) for r in rows]
        @test layout(failed) == layout(exact)
        ctx = (; rig = "r", rung = "builders")
        @test layout(CRS.dot_rows(ctx, cam, CRS.Failure("not detected"))) == layout(CRS.dot_rows(ctx, cam, [area_centroid(cam, c) for c in CRS.DOT_CENTRES]))
        # a frame the detector throws on is that frame's finding: its detection row says so
        thrown = CRS.frame_corners(cam, "no such video.mp4", 0, missing)
        @test thrown isa CRS.Failure && startswith(thrown.status, "threw: ")
    end

    @testset "rigs" begin
        @test only(CRS.select_rigs(["baseline"])) === first(VARIANTS)
        @test_throws ArgumentError CRS.select_rigs(["no such rig"])
        rig = Rig("wide", (; sar = 2 // 1))
        @test CRS.select_rigs([rig]) == [rig]
        @test Camera(rig).sar == 2 && Camera(rig).f == BASELINE_CAMERA.f
    end

    # the acceptance of #301: a baseline run lands near #292's numbers, and a failing rig is recorded
    # while the run goes on. #302 also measures the ten jittered baseline replicates.
    @testset "baseline run" begin
        results_dir, cache_dir = mktempdir(), mktempdir()
        broken = Rig("broken", (; f = -1.0))
        report = redirect_stdout(devnull) do
            simulate(; results_dir, cache_dir, variants = [first(VARIANTS), broken])
        end
        folder = joinpath(results_dir, only(readdir(results_dir)))
        for part in ("fromage-$(pkgversion(Fromage))", "simulation-$(pkgversion(CalibrationRigSimulation))", "julia-$VERSION")
            @test occursin(part, basename(folder))
        end
        @test nrow(CSV.read(joinpath(folder, "report.csv"), DataFrame)) == nrow(report)
        @test all(c -> c in names(report), ["floor", "ratio", "tolerance", "family", "verdict"])
        replicates = CSV.read(joinpath(folder, "replicates.csv"), DataFrame)
        @test length(unique(replicates.rig)) == 10
        @test all(==("ok"), replicates.status)
        @test all(==(true), skipmissing(replicates.passed))
        # one row per rig × rung × builder × section × quantity × split × statistic (× seed aggregate)
        key = [:rig, :rung, :builder, :section, :quantity, :split, :statistic, :aggregate, :unit]
        @test allunique(eachrow(coalesce.(report[:, key], "")))

        baseline = report[report.rig .== "baseline", :]
        @test all(==("ok"), baseline.status)
        @test !any(==("serious"), baseline.verdict)
        value(; kw...) = only(r.value for r in eachrow(baseline) if all(isequal(r[k], v) for (k, v) in kw))
        @test value(quantity = "detection", split = "all") == 28
        @test all(==(true), skipmissing(baseline.passed))
        @test count(!ismissing, baseline.passed) == 4
        map_rms(builder, section) = value(; builder, section, quantity = "map", split = "arena", statistic = "RMS", aggregate = section == "control" && builder == "from_extrinsic" ? "median" : missing)
        @test 0.1 < map_rms("from_checkerboard", "fromage") < 0.4
        @test 2 < map_rms("from_extrinsic", "fromage") < 4
        @test map_rms("from_checkerboard", "control") < CRS.CONTROL_TOLERANCE
        @test 1 < map_rms("from_extrinsic", "control") < 5
        @test value(quantity = "corners", split = "all frames", statistic = "RMS", unit = "stored px") < 0.15

        failed = only(eachrow(report[report.rig .== "broken", :]))
        @test failed.status == "threw: ArgumentError: f must be positive, got -1.0"
        @test ismissing(failed.value)

        # Exercise the printed markers and closing list using the real report's layout.
        rows = NamedTuple.(eachrow(baseline))
        plain = sprint(CRS.print_summary, rows)
        @test occursin("baseline rig's floor", plain) && occursin("serious rows: none", plain)
        missed = findfirst(r -> r.quantity == "detection" && r.split == "flat", rows)
        corners = findfirst(r -> r.quantity == "corners" && r.statistic == "RMS" && r.split == "all frames", rows)
        rows[missed] = merge(rows[missed], (; value = 0.0, verdict = "serious"))
        rows[corners] = merge(rows[corners], (; verdict = "diagnostic"))
        flagged = sprint(CRS.print_summary, rows)
        @test occursin("flat!!", flagged) && occursin("serious rows: 1", flagged)
        @test occursin("detection / flat / detected", flagged)
        @test occursin(CRS.fmt(rows[corners].value, "%7.3f") * "!", flagged)
        @info "Baseline acceptance: no serious rows; measured floors and replicates saved" folder cache_dir
    end
end
