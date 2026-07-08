# Coordinate-frame transforms: centering/northing, the perspective/depth helpers,
# the obj2img/img2obj inverse wiring, the warp builder, and pixel checker sizing.
# All pure (no I/O); we assert geometric invariants rather than hard-coded matrices.

@testset "geometry" begin

    @testset "fix_coordinate" begin
        @test R.fix_coordinate(missing, 2.0) === missing            # passthrough for "no point"
        # (x, y) ↦ (y, aspect*x): swaps axes and applies the aspect ratio
        @test R.fix_coordinate((3.0, 5.0), 2.0) == (5.0, 6.0)
        @test R.fix_coordinate((3.0, 5.0), 1.0) == (5.0, 3.0)
    end

    @testset "i2r_centering" begin
        # centering translates so the chosen point lands on the world origin
        i2r = LinearMap(SDiagonal(SVector(2.0, 3.0)))
        c = SVector(4.0, 5.0)
        centering = R.i2r_centering(i2r, c)
        @test (centering ∘ i2r)(c) ≈ SVector(0.0, 0.0) atol = 1e-12
    end

    @testset "i2r_northing" begin
        i2r = IdentityTransformation()
        cen = R.i2r_centering(i2r, SVector(2.0, 3.0))
        # no north point ⇒ identity rotation
        @test R.i2r_northing(i2r, cen, missing) isa IdentityTransformation
        # with a north point, (northing ∘ centering ∘ image2real)(north) lands on the −x axis (angle π)
        n = SVector(2.0, 5.0)
        northing = R.i2r_northing(i2r, cen, n)
        p = (northing ∘ cen)(n)
        @test p[2] ≈ 0.0 atol = 1e-12
        @test p[1] < 0
    end

    @testset "i2r_centering_northing" begin
        i2r = LinearMap(SDiagonal(SVector(1.5, 2.0)))
        c, n = SVector(3.0, 4.0), SVector(6.0, 9.0)
        centering, northing = R.i2r_centering_northing(i2r, c, n)
        @test (centering ∘ i2r)(c) ≈ SVector(0.0, 0.0) atol = 1e-12
        @test centering == R.i2r_centering(i2r, c)
    end

    @testset "add_center_north" begin
        aspect = 1.3
        image2real = LinearMap(0.5 * SDiagonal(SVector(1.0, aspect)))
        real2image = inv(image2real)
        center, north = (10.0, 20.0), (15.0, 40.0)
        i2r, r2i = R.add_center_north(image2real, real2image, center, north, aspect)
        # image2real and real2image stay mutual inverses after augmentation
        for p in (SVector(0.0, 0.0), SVector(12.0, -7.0), SVector(100.0, 50.0))
            @test (r2i ∘ i2r)(p) ≈ p atol = 1e-9
        end
        # the (aspect-fixed) center maps to the world origin, north onto the −x axis
        fc_center = SVector(R.fix_coordinate(center, aspect))
        fc_north = SVector(R.fix_coordinate(north, aspect))
        @test i2r(fc_center) ≈ SVector(0.0, 0.0) atol = 1e-9
        pn = i2r(fc_north)
        @test pn[2] ≈ 0.0 atol = 1e-9
        @test pn[1] < 0
    end

    @testset "depth & inverse perspective" begin
        # depth(rc1, t, l) = -t / (l⋅rc1)
        @test R.depth(SVector(1.0, 2.0, 1.0), 5.0, SVector(0.0, 0.0, 2.0)) ≈ -2.5
        # get_inv_prespective_map: rc ↦ d·[rc; 1] with d from the extrinsic's last row & z-translation
        inv_extrinsic = AffineMap(SMatrix{3,3}(1.0I), SVector(0.0, 0.0, 5.0))
        f = R.get_inv_prespective_map(inv_extrinsic)
        rc = SVector(1.0, 2.0)
        out = f(rc)
        rc1 = SVector(1.0, 2.0, 1.0)
        d = R.depth(rc1, 5.0, SVector(0.0, 0.0, 1.0))   # last row of identity linear part
        @test out ≈ d .* rc1
        @test out[3] ≈ d                                 # recovered depth sits in the z slot
    end

    @testset "obj2img / img2obj inverse wiring" begin
        Rvec = (0.1, -0.2, 0.05)
        t = (0.3, 0.4, 5.0)
        frow, fcol, crow, ccol = 800.0, 810.0, 320.0, 240.0
        checker_size = 0.025
        k = (0.05, -0.01)
        intrinsic, extrinsic, scale = R.obj2img(Rvec, t, frow, fcol, crow, ccol, checker_size)
        inv_scale, inv_extrinsic, _, inv_distort, inv_intrinsic =
            R.img2obj(intrinsic, extrinsic, scale, k)
        # img2obj hands back genuine inverses of obj2img's components
        for p in (SVector(0.0, 0.0), SVector(123.0, -45.0))
            @test (inv_intrinsic ∘ intrinsic)(p) ≈ p atol = 1e-9
        end
        for p in (SVector(0.1, 0.2, 0.3), SVector(-1.0, 2.0, 5.0))
            @test (inv_extrinsic ∘ extrinsic)(p) ≈ p atol = 1e-9
            @test (inv_scale ∘ scale)(p) ≈ p atol = 1e-9
        end
        # inv_distort inverts the forward radial map
        v = SVector(0.2, -0.1)
        @test inv_distort(R.lens_distortion(v, k)) ≈ v atol = 1e-9
    end

    @testset "get_warp" begin
        # get_warp prepends a ratio·I scaling before real2image
        warp = R.get_warp(2.0, IdentityTransformation())
        @test warp(SVector(1.0, 1.0)) ≈ SVector(2.0, 2.0)
        warp2 = R.get_warp(3.0, LinearMap(SDiagonal(SVector(0.5, 0.5))))
        @test warp2(SVector(1.0, 2.0)) ≈ SVector(1.5, 3.0)   # 3·0.5 = 1.5 per axis
    end

    @testset "default_center" begin
        # no center given ⇒ frame centre in (w, h) pixel coordinates
        @test R.default_center(missing, 640, 480) == SVector(320.0, 240.0)
        @test R.default_center(missing, 100, 50) == SVector(50.0, 25.0)
        # an explicit center passes straight through, untouched
        @test R.default_center(SVector(1.0, 2.0), 640, 480) == SVector(1.0, 2.0)
        @test R.default_center((10, 20), 640, 480) === (10, 20)
    end

    @testset "checker_size_pixel" begin
        # a perfectly regular grid with spacing d ⇒ averaged edge length is exactly d
        d = 2.5f0
        n_corners = (3, 4)
        corners = [SVector{2,Float32}((i - 1) * d, (j - 1) * d)
                   for i in 1:n_corners[1], j in 1:n_corners[2]]
        @test R.checker_size_pixel(corners, n_corners) ≈ d
    end

end
