# Unit tests for the AprilTag ground-plane geometry (src/PawsomeTracker/apriltag.jl). All tests are
# synthetic and deterministic: a known camera homography maps a known four-tag ground layout into
# an image; the geometry must invert it (recover metric ground coordinates) without the detector
# or any video. The behaviour matches what was verified live against the real drone frame.
module ApriltagTests

using Test
using StaticArrays
using LinearAlgebra
# the geometry is internal to the submodule; import the (non-exported) names directly
using Fromage.PawsomeTracker: CANON, apply_h, homography_dlt, place_square, fit_metric,
    _worst_side, ReferenceFrame, register, ground_homography

rot(θ) = SMatrix{2,2,Float64}(cos(θ), sin(θ), -sin(θ), cos(θ))    # proper 2D rotation

# a realistic near-nadir drone view (mild perspective, like the real footage), and a deliberately
# harsh one (strong perspective) for the robustness check
const HMILD  = SMatrix{3,3,Float64}(1.5, -0.03, 5e-6, 0.05, 1.5, 3e-6, 960.0, 540.0, 1.0)
const HHARSH = SMatrix{3,3,Float64}(1.5, -0.05, 1e-4, 0.10, 1.4, 5e-5, 960.0, 540.0, 1.0)
const HMILD2 = SMatrix{3,3,Float64}(1.4,  0.06, -4e-6, -0.08, 1.45, 4e-6, 900.0, 600.0, 1.0)

# a four-tag ground layout (spread out, each tag slightly rotated) as 96 cm squares, in cm
const CENTERS = SVector{2,Float64}[SVector(-400, -400), SVector(400, -400), SVector(400, 400), SVector(-400, 400)]
const ANGLES  = [0.10, -0.20, 0.15, -0.05]
const TAGS_CM = [[CENTERS[i] + rot(ANGLES[i]) * c for c in CANON] for i in 1:4]
project(H) = [[apply_h(H, c) for c in tc] for tc in TAGS_CM]

@testset "AprilTag geometry (phase 1)" begin

    @testset "homography_dlt recovers a known homography" begin
        pts = SVector{2,Float64}[SVector(1400, 880), SVector(1500, 890), SVector(1490, 970), SVector(1395, 965), SVector(1445, 925)]
        dst = [apply_h(HMILD, p) for p in pts]
        H = homography_dlt(pts, dst)
        @test maximum(norm(apply_h(H, pts[i]) - dst[i]) for i in eachindex(pts)) < 1e-8
    end

    @testset "place_square recovers a true 96 cm square" begin
        placed = [rot(0.3) * c + SVector(120.0, -50) for c in CANON]
        fit = place_square(placed)
        @test all(norm(fit[i] - fit[mod1(i+1,4)]) ≈ 96.0 for i in 1:4)
        @test maximum(norm(fit[i] - placed[i]) for i in 1:4) < 1e-9
    end

    @testset "fit_metric makes every tag a 96 cm square, jointly (not one tag)" begin
        M = fit_metric(project(HMILD))
        @test _worst_side(M, project(HMILD)) < 1e-3                  # every tag metric
        # metric scale is correct: a known ground distance is recovered (gauge-invariant)
        a, b = CENTERS[1], CENTERS[3]
        â = apply_h(M, apply_h(HMILD, a)); b̂ = apply_h(M, apply_h(HMILD, b))
        @test norm(â - b̂) ≈ norm(a - b) rtol = 1e-4
    end

    @testset "robust under strong perspective (gauge-pinned consensus)" begin
        @test _worst_side(fit_metric(project(HHARSH)), project(HHARSH)) < 0.1
    end

    @testset "non-coplanar / mis-detected tags fail loudly, not silently" begin
        bad = project(HMILD)                                         # tag 4 is a 150 cm square,
        bad[4] = [apply_h(HMILD, CENTERS[4] + rot(ANGLES[4]) * (c * 150/96)) for c in CANON]  # not 96
        @test_throws ErrorException fit_metric(bad)
    end

    @testset "registration is drone-motion invariant: one ground point, two frames" begin
        ref = ReferenceFrame([0,1,2,3], project(HMILD))
        beetle = SVector(37.0, -88.0)                                # a ground point (cm)
        img1 = project(HMILD); img2 = project(HMILD2)                # same tags, two drone poses
        b1 = apply_h(HMILD, beetle); b2 = apply_h(HMILD2, beetle)    # beetle seen in each frame
        cm1 = apply_h(ground_homography(ref, reduce(vcat, img1)), b1)
        cm2 = apply_h(ground_homography(ref, reduce(vcat, img2)), b2)
        @test norm(cm1 - cm2) < 1e-4                                 # same cm despite drone move
        # metric accuracy through a NON-reference frame: a known ground distance is recovered
        g1, g2 = SVector(50.0, -30.0), SVector(-90.0, 110.0)
        Gh = ground_homography(ref, reduce(vcat, img2))
        d̂ = norm(apply_h(Gh, apply_h(HMILD2, g1)) - apply_h(Gh, apply_h(HMILD2, g2)))
        @test d̂ ≈ norm(g1 - g2) rtol = 1e-4
    end
end

end
