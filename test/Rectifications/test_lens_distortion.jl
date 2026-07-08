# Radial lens-distortion math: the forward factor/map, the critical (fold) radius,
# and the bracketed-bisection inverse. All pure, no I/O.

@testset "lens distortion" begin

    @testset "lens_distortion_factor" begin
        # f(r) = 1 + k₁r² + k₂r⁴ + k₃r⁶
        @test R.lens_distortion_factor(3.7, ()) == 1.0          # no coefficients ⇒ identity factor
        @test R.lens_distortion_factor(0.0, (0.5, -0.2)) == 1.0 # r = 0 ⇒ 1 regardless of k
        @test R.lens_distortion_factor(2.0, (0.5,)) ≈ 1 + 0.5 * 4                       # 3.0
        @test R.lens_distortion_factor(2.0, (0.5, 0.25)) ≈ 1 + 0.5 * 4 + 0.25 * 16      # 7.0
        @test R.lens_distortion_factor(2.0, (0.1, -0.05, 0.01)) ≈
              1 + 0.1 * 4 - 0.05 * 16 + 0.01 * 64                                       # 1.24
    end

    @testset "lens_distortion" begin
        k = (0.1, -0.05, 0.01)
        @test R.lens_distortion(SVector(0.0, 0.0), k) == SVector(0.0, 0.0)   # origin is a fixed point
        @test R.lens_distortion(SVector(3.0, 4.0), ()) == SVector(3.0, 4.0)  # k = () ⇒ identity map
        v = SVector(0.3, 0.2)
        vd = R.lens_distortion(v, k)
        # distortion is purely radial ⇒ output is collinear with input (2D cross product ≈ 0)
        @test v[1] * vd[2] - v[2] * vd[1] ≈ 0 atol = 1e-12
        @test vd ≈ v .* R.lens_distortion_factor(norm(v), k)
    end

    @testset "_first_critical" begin
        @test R._first_critical(()) == Inf                # no distortion ⇒ globally monotone
        @test R._first_critical((0.5,)) == Inf            # pincushion (k₁>0) never folds
        # barrel (k₁<0): g'(r)=1+3k₁r²=0 ⇒ r=√(-1/(3k₁)); for k₁=-0.5 ⇒ √(2/3)
        @test R._first_critical((-0.5,)) ≈ sqrt(2 / 3)
        # at the fold the radial map's derivative g'(r)=1+3k₁r²+5k₂r⁴+7k₃r⁶ vanishes
        let k = (-0.5,), rstar = R._first_critical((-0.5,))
            gprime = 1 + 3k[1] * rstar^2
            @test gprime ≈ 0 atol = 1e-12
        end
        # multiple positive critical radii: derivative (in s=r²) chosen as 1 - 5s + 4s²,
        # roots s = 0.25, 1.0 ⇒ smallest fold radius is √0.25 = 0.5. Coeffs: 3k₁=-5, 5k₂=4.
        @test R._first_critical((-5 / 3, 0.8)) ≈ 0.5
    end

    @testset "inv_lens_distortion round-trip" begin
        # inverse∘forward ≈ identity across a grid of points and several distortion regimes,
        # all kept inside the invertible radius.
        for k in ((), (0.1,), (-0.05,), (0.1, -0.02), (0.1, -0.02, 0.005), (0.2,))
            for x in -0.4:0.2:0.4, y in -0.4:0.2:0.4
                v = SVector(x, y)
                @test R.inv_lens_distortion(R.lens_distortion(v, k), k) ≈ v atol = 1e-9
            end
        end
        @test R.inv_lens_distortion(SVector(0.0, 0.0), (0.1, -0.02)) == SVector(0.0, 0.0)
        # monotone (rstar = Inf) branch must also invert correctly
        @test R.inv_lens_distortion(R.lens_distortion(SVector(0.3, 0.0), (0.2,)), (0.2,)) ≈
              SVector(0.3, 0.0) atol = 1e-9
    end

    @testset "inv_lens_distortion beyond the fold" begin
        # NOTE: the clamp warning uses `maxlog = 1`, so it fires only once per process.
        # This must be the FIRST beyond-fold call in the suite — the round-trips above stay
        # in range, so no earlier clamp consumes the single allowed warning.
        k = (-0.5,)
        rstar = R._first_critical(k)
        g(r) = r * R.lens_distortion_factor(r, k)
        v2 = SVector(g(rstar) * 1.2, 0.0)   # distorted radius past the invertible branch
        clamped = @test_logs (:warn,) R.inv_lens_distortion(v2, k, rstar)
        @test norm(clamped) ≈ rstar               # radius clamped to the fold
        @test clamped[2] == 0.0                    # direction of v2 preserved (on the +x axis)
        @test clamped[1] > 0
    end

end
