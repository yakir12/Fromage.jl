using CalibrationRigSimulation: CalibrationRigSimulation, Camera, project, ray
using LinearAlgebra: normalize
using OpenCV: OpenCV
using StaticArrays: SVector
using Test: @test, @testset

const CRS = CalibrationRigSimulation

# the baseline rig's camera (#289, #291), at any lens and `sar`
camera(k, sar) = Camera(;
    position = SVector(1.5, 0.0, 1.5), target = SVector(0.0, 0.0, 0.0),
    f = 900.0, principal_point = SVector(971.8, 531.7), k, sar,
)

# the `k1` variants (#289), the canonical no distortion, and a `k1 + k2` lens. That lens's values
# are this test's own; #304 fixes the one the variants use.
const LENSES = [
    (0.0, 0.0, 0.0),
    (-0.05, 0.0, 0.0), (-0.15, 0.0, 0.0), (-0.3, 0.0, 0.0), (0.05, 0.0, 0.0),
    (-0.25, 0.08, 0.0),
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
end
