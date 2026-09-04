# Unit tests for the AprilTag ground-plane geometry (src/PawsomeTracker/apriltag.jl). All tests are
# synthetic and deterministic: a known camera homography maps a known four-tag ground layout into
# an image; the geometry must invert it (recover metric ground coordinates) without the detector
# or any video. The behaviour matches what was verified live against the real drone frame.
module ApriltagTests

using Test
using StaticArrays
using Random: Xoshiro
using LinearAlgebra
# the geometry is internal to the submodule; import the (non-exported) names directly
using Fromage.PawsomeTracker: CANON, apply_h, homography_dlt, place_square, fit_metric, rigid_align,
    _worst_side, ReferenceFrame, register,
    RegisteredWarp, build_stack, canvas2raw, Gray, N0f8, METRIC_FIT_TOLERANCE,
    ApriltagScene, apriltag_image2real, _real_to_canvas, DIAGNOSTIC_SIZE

rot(θ) = SMatrix{2,2,Float64}(cos(θ), sin(θ), -sin(θ), cos(θ))    # proper 2D rotation

# The background stack is a lazily-indexed view over the array that actually holds the frames, and
# how many layers of view sit in between is nobody's business but `build_stack`'s. Unwrap to the
# storage rather than naming a depth, so a change in the pipe doesn't read as a test failure.
storage(a) = parent(a) === a ? a : storage(parent(a))


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

@testset "AprilTag geometry" begin

    @testset "rigid_align recovers a rotation and never mirrors" begin
        # Kabsch with a reflection guard: it must recover a genuine rotation+translation exactly,
        # and must REFUSE to mirror — a reflected target is not reachable by a rigid map, so the
        # best proper rotation is the right answer there rather than an exact fit. `rigid_align`
        # is otherwise only covered through place_square and fit_metric.
        src = SVector{2,Float64}[SVector(0, 0), SVector(1, 0), SVector(1, 1), SVector(0, 1)]
        R, t = rot(0.7), SVector(3.0, -2.0)
        dst = [R * p + t for p in src]
        f = rigid_align(src, dst)
        @test all(f(src[i]) ≈ dst[i] for i in eachindex(src))     # exact on a true rigid motion

        # the recovered linear part is a proper rotation (det +1), both here and on a mirrored
        # target, which is what the guard is for
        lin(g) = hcat(g(SVector(1.0, 0.0)) - g(SVector(0.0, 0.0)), g(SVector(0.0, 1.0)) - g(SVector(0.0, 0.0)))
        @test det(lin(f)) ≈ 1
        mirrored = [SVector(p[2], p[1]) for p in src]              # swaps handedness
        @test det(lin(rigid_align(src, mirrored))) ≈ 1
    end

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
        M, err = fit_metric(project(HMILD))
        @test err < 1e-3                                             # converged
        @test _worst_side(M, project(HMILD)) < 1e-3                  # every tag metric
        # metric scale is correct: a known ground distance is recovered (gauge-invariant)
        a, b = CENTERS[1], CENTERS[3]
        â = apply_h(M, apply_h(HMILD, a)); b̂ = apply_h(M, apply_h(HMILD, b))
        @test norm(â - b̂) ≈ norm(a - b) rtol = 1e-4
    end

    @testset "robust under strong perspective (gauge-pinned consensus)" begin
        @test _worst_side(first(fit_metric(project(HHARSH))), project(HHARSH)) < 0.1
    end

    @testset "non-coplanar / mis-detected tags fail loudly, not silently" begin
        bad = project(HMILD)                                         # tag 4 is a 150 cm square,
        bad[4] = [apply_h(HMILD, CENTERS[4] + rot(ANGLES[4]) * (c * 150/96)) for c in CANON]  # not 96
        # fit_metric computes and reports; it does not decide. The error it returns is well past
        # the tolerance, and the direct constructor still turns that into a throw.
        @test last(fit_metric(bad)) > METRIC_FIT_TOLERANCE
        @test_throws ErrorException ReferenceFrame([0,1,2,3], bad)
    end

    @testset "registration is drone-motion invariant: one ground point, two frames" begin
        ref = ReferenceFrame([0,1,2,3], project(HMILD))
        beetle = SVector(37.0, -88.0)                                # a ground point (cm)
        img1 = project(HMILD); img2 = project(HMILD2)                # same tags, two drone poses
        b1 = apply_h(HMILD, beetle); b2 = apply_h(HMILD2, beetle)    # beetle seen in each frame
        cm1 = apply_h(ref.M * register(ref, reduce(vcat, img1)), b1)
        cm2 = apply_h(ref.M * register(ref, reduce(vcat, img2)), b2)
        @test norm(cm1 - cm2) < 1e-4                                 # same cm despite drone move
        # metric accuracy through a NON-reference frame: a known ground distance is recovered
        g1, g2 = SVector(50.0, -30.0), SVector(-90.0, 110.0)
        Gh = ref.M * register(ref, reduce(vcat, img2))
        d̂ = norm(apply_h(Gh, apply_h(HMILD2, g1)) - apply_h(Gh, apply_h(HMILD2, g2)))
        @test d̂ ≈ norm(g1 - g2) rtol = 1e-4
    end

    @testset "RegisteredWarp: the registered background stack is drone-motion invariant" begin
        # three "drone" frames = crops of one static ground image at different offsets; with each
        # slice's registration in the warp, every slice must reproduce the SAME static scene at the
        # same canvas index, and so must the per-pixel reduction over slices (the background model)
        # — the property the registered stack exists for. Integer translations keep the
        # interpolation exact, so the comparisons are to machine precision.
        # N0f8, matching what the stack actually holds: frames arrive already 8-bit from the
        # decoder, so nothing is quantised in production. Float32-precision ground data would be
        # rounded on write and the exactness assertions below would measure that rounding rather
        # than the registration they are here to test (#27).
        # Seeded: the assertions below are exact-copy invariants that hold for ANY array, so the
        # values are incidental — but an unseeded fixture makes a failure irreproducible from
        # the log, which is the hazard DESIGN-HISTORY's "corrupt-video fixture is deterministic"
        # entry already records once.
        ground = Gray{N0f8}.(rand(Xoshiro(20260901), N0f8, 100, 120))
        offs = [(0, 0), (5, 7), (10, 3)]                                   # (row, col) crop offsets
        Hc, Wc = 60, 70
        Hinv(o) = SMatrix{3,3,Float64}(1, 0, 0, 0, 1, 0, -o[2], -o[1], 1)  # ref (x,y) → frame (x,y)
        w = RegisteredWarp(1.0, [Hinv(o) for o in offs])
        stack = build_stack(w, (Hc, Wc), (Hc, Wc), 3, (1:Hc, 1:Wc, 1:3))
        raw = storage(stack)
        for (k, (oy, ox)) in enumerate(offs)
            raw[:, :, k] .= ground[oy+1:oy+Hc, ox+1:ox+Wc]
        end
        r, c = 11:Hc, 8:Wc                                                 # the overlap of all three crops
        @test all(maximum(abs, Float32.(stack[r, c, k]) .- Float32.(ground[r, c])) < 1e-6 for k in 1:3)
        bg = dropdims(maximum(Float32.(stack[r, c, :]), dims = 3), dims = 3)
        @test maximum(abs, bg .- Float32.(ground[r, c])) < 1e-6

        # the warp composes the inverse scaling exactly like the plain stack's LinearMap: canvas
        # (r, c) samples the frame at the registration of (r, c)/scale. Two slices — a
        # single-slice stack has no valid linear-interpolation stencil along the slice axis
        # (production stacks always hold ≥ 2 frames).
        w2 = RegisteredWarp(0.5, [Hinv(offs[2]), Hinv(offs[3])])
        stack2 = build_stack(w2, (Hc ÷ 2, Wc ÷ 2), (Hc, Wc), 2, (1:Hc÷2, 1:Wc÷2, 1:2))
        for (k, (oy, ox)) in enumerate((offs[2], offs[3]))
            storage(stack2)[:, :, k] .= ground[oy+1:oy+Hc, ox+1:ox+Wc]
        end
        @test Float32(stack2[10, 12, 1]) ≈ Float32(ground[20, 24]) atol = 1e-6
        @test Float32(stack2[10, 12, 2]) ≈ Float32(ground[20, 24]) atol = 1e-6

        # canvas2raw is the warp's 2D core: canvas (row, col) → raw frame (row, col)
        c2r = canvas2raw(Hinv((5, 7)), 1.0)
        @test all(c2r((20, 30)) .≈ (15.0, 23.0))
    end

    @testset "the diagnostic canvas is gauged by center/north, not by the tag fit" begin
        # `fit_metric` pins its cm frame to the lowest-numbered tag's BODY, so the SAME terrain
        # yields metric maps differing by a rigid transform when that one board is turned between
        # field days — which turned the whole diagnostic canvas with it, and made two runs over one
        # arena impossible to compare. Turning the board is modelled here as `M2 = rot * M`: an
        # equally valid metric fit (every tag is still a true square, asserted below) in a rotated
        # gauge. With `center`/`north` naming the same two PHYSICAL points in both, the canvas must
        # come out identical. Before the gauge reached the scene, these differed by the rotation.
        ref = ReferenceFrame([0,1,2,3], project(HMILD))
        R90 = SMatrix{3,3,Float64}(0, 1, 0, -1, 0, 0, 0, 0, 1)          # cm frame turned 90°
        M2 = R90 * ref.M
        ref2 = ReferenceFrame(ref.ids, ref.corners, M2)
        @test _worst_side(M2, project(HMILD)) ≈ _worst_side(ref.M, project(HMILD))

        # center/north as REFERENCE-IMAGE pixels: both frames share one reference image, so the
        # same pixels are the same physical points — exactly the user-facing promise being tested.
        centre_px, north_px = SVector(960.0, 540.0), SVector(1200.0, 300.0)
        scene(r) = ApriltagScene(r, apriltag_image2real(r.M, centre_px, north_px, 1920, 1080, 1.0))
        s1, s2 = scene(ref), scene(ref2)

        probes = [SVector(x, y) for x in (700.0, 960.0, 1300.0), y in (350.0, 540.0, 800.0)]
        onto(s, r, p) = _real_to_canvas(s, s.gauge(apply_h(r.M, p)))
        # the assertion has teeth only because the two metric frames genuinely disagree: the same
        # physical point has different raw cm under each, which is what used to reach the canvas
        @test all(!isapprox(apply_h(ref.M, p), apply_h(M2, p)) for p in probes)
        @test all(onto(s1, ref, p) == onto(s2, ref2, p) for p in probes)
        # and the canvas really is populated, not collapsed to a point by a degenerate gauge
        @test length(unique(onto(s1, ref, p) for p in probes)) == length(probes)

        # north lands up the canvas (negative first axis; see i2r_northing) and centre at the origin
        @test s1.gauge(apply_h(ref.M, centre_px)) ≈ SVector(0.0, 0.0) atol = 1e-9
        gn = s1.gauge(apply_h(ref.M, north_px))
        @test gn[1] < 0 && abs(gn[2]) < 1e-9
        # the gauge inverts, which is what lets the warp sample the source frame
        @test all(s1.ungauge(s1.gauge(apply_h(ref.M, p))) ≈ apply_h(ref.M, p) for p in probes)
    end

    @testset "without north the canvas is unchanged: raw cm, framed on the tags" begin
        # The gauge's rotation is the identity when `north` is missing, and its translation is
        # absorbed by centring the canvas on the tags' bounding box — so every calibration that
        # does not set `north` must render exactly as it did before the scene was gauged. This is
        # the no-regression half of the change; the formula on the right is the previous one.
        ref = ReferenceFrame([0,1,2,3], project(HMILD))
        s = ApriltagScene(ref, apriltag_image2real(ref.M, missing, missing, 1920, 1080, 1.0))

        cm = [apply_h(ref.M, p) for p in ref.corners]
        xlo, xhi = extrema(first, cm)
        ylo, yhi = extrema(last, cm)
        extent = max(xhi - xlo, yhi - ylo)
        ppc = DIAGNOSTIC_SIZE / (extent + 2 * 0.15 * extent)
        xc, yc = (xlo + xhi) / 2, (ylo + yhi) / 2
        was(p) = (c = apply_h(ref.M, p);
                  CartesianIndex(round(Int, (c[2] - yc) * ppc + DIAGNOSTIC_SIZE/2),
                                 round(Int, (c[1] - xc) * ppc + DIAGNOSTIC_SIZE/2)))

        probes = [SVector(x, y) for x in (700.0, 960.0, 1300.0), y in (350.0, 540.0, 800.0)]
        @test all(_real_to_canvas(s, s.gauge(apply_h(ref.M, p))) == was(p) for p in probes)
        @test s.ppc ≈ ppc
    end
end

end
