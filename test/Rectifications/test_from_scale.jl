# `from_scale` (from_scale.jl): a pure affine rectification with no
# camera calibration. Without `diagnostic` it never touches the video, so we test it as a transform.
# (The `diagnostic` branch reuses `warp_extrinsic` + FileIO.save, already exercised by Tier 3.)

@testset "scale-based Rectification" begin

    @testset "scales pixel steps into real units" begin
        for (scale, aspect) in ((0.5, 1.0), (2.0, 1.0), (0.5, 1.4))
            rect = R.from_scale(; file = "unused.mp4", extrinsic = 0.0, scale, aspect,
                center = missing, north = missing, width = 640, height = 480)
            image2real = rect.image2real
            p0 = SVector(100.0, 120.0)
            dx = image2real(p0 + SVector(1.0, 0.0)) - image2real(p0)
            dy = image2real(p0 + SVector(0.0, 1.0)) - image2real(p0)
            @test hypot(dx...) ≈ scale             # one pixel in x ⇒ `scale` in world units
            @test hypot(dy...) ≈ scale * aspect    # one pixel in y ⇒ `scale·aspect`
            # the constructor returns (; image2real, real2image, ratio, width, height)
            @test rect.real2image(rect.image2real(p0)) ≈ p0    # the two maps are inverses
            @test rect.ratio == scale
            @test (rect.width, rect.height) == (640, 480)
        end
    end

    @testset "center defaults to frame centre" begin
        # center = missing must reproduce the explicit frame-centre pixel exactly
        scaled(; kw...) = R.from_scale(; file = "unused.mp4", extrinsic = 0.0, scale = 0.5, aspect = 1.0,
            center = missing, north = missing, width = 640, height = 480, kw...)
        i2r_def = scaled().image2real
        i2r_exp = scaled(center = SVector(320.0, 240.0)).image2real
        for p in (SVector(0.0, 0.0), SVector(50.0, -30.0), SVector(640.0, 480.0))
            @test i2r_def(p) ≈ i2r_exp(p)
        end
    end

    @testset "northing preserves scale (rigid rotation)" begin
        # supplying a north point rotates the world frame; distances must be preserved
        i2r = R.from_scale(; file = "unused.mp4", extrinsic = 0.0, scale = 0.5, aspect = 1.0,
            center = SVector(320.0, 240.0), north = SVector(320.0, 100.0), width = 640, height = 480).image2real
        p0 = SVector(100.0, 120.0)
        @test hypot((i2r(p0 + SVector(1.0, 0.0)) - i2r(p0))...) ≈ 0.5
        @test hypot((i2r(p0 + SVector(0.0, 1.0)) - i2r(p0))...) ≈ 0.5
    end

end
