# `from_scale` (from_scale.jl): a pure affine rectification with no
# camera calibration. Without `diagnostic` it never touches the video, so we test it as a transform.
# (The `diagnostic` branch reuses `warp_extrinsic` + FileIO.save, already exercised by Tier 3.)

@testset "scale-based Rectification" begin

    @testset "scales pixel steps into real units" begin
        for (scale, aspect) in ((0.5, 1.0), (2.0, 1.0), (0.5, 1.4))
            rect = R.from_scale(; rectification_diagnostics = false, file = "unused.mp4", extrinsic = 0.0, calibration_id = "s", scale, aspect,
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
        scaled(; kw...) = R.from_scale(; rectification_diagnostics = false, file = "unused.mp4", extrinsic = 0.0, calibration_id = "s", scale = 0.5, aspect = 1.0,
            center = missing, north = missing, width = 640, height = 480, kw...)
        i2r_def = scaled().image2real
        i2r_exp = scaled(center = SVector(320.0, 240.0)).image2real
        for p in (SVector(0.0, 0.0), SVector(50.0, -30.0), SVector(640.0, 480.0))
            @test i2r_def(p) ≈ i2r_exp(p)
        end
    end

    @testset "northing preserves scale (rigid rotation)" begin
        # supplying a north point rotates the world frame; distances must be preserved
        i2r = R.from_scale(; rectification_diagnostics = false, file = "unused.mp4", extrinsic = 0.0, calibration_id = "s", scale = 0.5, aspect = 1.0,
            center = SVector(320.0, 240.0), north = SVector(320.0, 100.0), width = 640, height = 480).image2real
        p0 = SVector(100.0, 120.0)
        @test hypot((i2r(p0 + SVector(1.0, 0.0)) - i2r(p0))...) ≈ 0.5
        @test hypot((i2r(p0 + SVector(0.0, 1.0)) - i2r(p0))...) ≈ 0.5
    end

    # `center`/`north` are DISPLAY pixels: display x = stored col × aspect. This is the convention
    # `start_location` already uses (see test/VerifyRuns/test_tracking.jl), and `center` feeds that
    # same slot, so the two must agree. Before #130 the conversion went the wrong way and every
    # anamorphic rectification was displaced by (aspect - 1) × x — half a frame at aspect 2.
    @testset "center/north are display pixels (#130)" begin
        W, H = 640, 480
        stored_centre = SVector(H / 2, W / 2)          # image (row, col) — the true frame centre

        for aspect in (1.0, 2.0, 0.5, 1.4)
            display_w = W * aspect
            rect(c) = R.from_scale(; rectification_diagnostics = false, file = "unused.mp4", extrinsic = 0.0, calibration_id = "s",
                scale = 0.5, aspect, center = c, north = missing, width = W, height = H)

            # the default centre must be the true frame centre, whatever the aspect
            @test rect(missing).real2image(SVector(0.0, 0.0)) ≈ stored_centre

            # and an explicitly given display-space centre must land in the same place
            @test rect(SVector(display_w / 2, H / 2)).real2image(SVector(0.0, 0.0)) ≈ stored_centre

            # a centre off to one side maps to stored col = x / aspect, not x * aspect
            x = display_w / 4
            @test rect(SVector(x, H / 2)).real2image(SVector(0.0, 0.0)) ≈ SVector(H / 2, W / 4)
        end

        # north is converted the same way: due north of centre in display space must come out due
        # north in real space (real y increases downward, so north is -y)
        r = R.from_scale(; rectification_diagnostics = false, file = "unused.mp4", extrinsic = 0.0, calibration_id = "s", scale = 0.5,
            aspect = 2.0, center = SVector(640.0, 240.0), north = SVector(640.0, 100.0),
            width = W, height = H)
        up = r.image2real(SVector(100.0, 320.0))       # a point above the centre, stored (row, col)
        @test up[1] < 0                                # north lies along -y
        @test isapprox(up[2], 0.0; atol = 1e-9)        # and squarely on the axis
    end

end
