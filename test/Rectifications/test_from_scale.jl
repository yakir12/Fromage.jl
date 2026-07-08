# The scale-based `Rectification` constructor (from_scale.jl): a pure affine rectification with no
# camera calibration. Without `diagnostic` it never touches the video, so we test it as a transform.
# (The `diagnostic` branch reuses `warp_extrinsic` + FileIO.save, already exercised by Tier 3.)

@testset "scale-based Rectification" begin

    @testset "scales pixel steps into real units" begin
        for (scale, aspect) in ((0.5, 1.0), (2.0, 1.0), (0.5, 1.4))
            rect = R.Rectification("unused.mp4", 0.0, scale, aspect,
                missing, missing, 640, 480)
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
        i2r_def = R.Rectification("unused.mp4", 0.0, 0.5, 1.0, missing, missing, 640, 480).image2real
        i2r_exp = R.Rectification("unused.mp4", 0.0, 0.5, 1.0, SVector(320.0, 240.0), missing, 640, 480).image2real
        for p in (SVector(0.0, 0.0), SVector(50.0, -30.0), SVector(640.0, 480.0))
            @test i2r_def(p) ≈ i2r_exp(p)
        end
    end

    @testset "northing preserves scale (rigid rotation)" begin
        # supplying a north point rotates the world frame; distances must be preserved
        i2r = R.Rectification("unused.mp4", 0.0, 0.5, 1.0,
            SVector(320.0, 240.0), SVector(320.0, 100.0), 640, 480).image2real
        p0 = SVector(100.0, 120.0)
        @test hypot((i2r(p0 + SVector(1.0, 0.0)) - i2r(p0))...) ≈ 0.5
        @test hypot((i2r(p0 + SVector(0.0, 1.0)) - i2r(p0))...) ≈ 0.5
    end

end
