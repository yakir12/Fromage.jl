# OpenCV-backed calibration: synthetic chessboard corner detection and the camera-model fit.
# No video/ffmpeg here — `_detect_corners` and `fit_model` work on in-memory arrays/points, with
# OpenCV pulled in transitively by the package. We drive both with deterministic synthetic data
# and assert recovery of the known camera (plus sub-pixel reprojection), the strongest invariant.

@testset "calibration (OpenCV)" begin

    # --- synthetic scene helpers (local to this testset) -------------------------------------

    # Render a checkerboard with `inner` inner-corners, `sq`-px squares and an `m`-px white quiet
    # border, in the (1, h, w) UInt8 layout `_detect_corners` expects.
    function checkerboard(inner::Tuple{Int,Int}; sq = 30, m = 40)
        nx, ny = inner                       # inner corners ⇒ (nx+1)×(ny+1) squares
        bw, bh = (nx + 1) * sq, (ny + 1) * sq
        w, h = bw + 2m, bh + 2m
        img = fill(0xff, 1, h, w)            # white background
        for row in 1:h, col in 1:w
            (m < col ≤ m + bw && m < row ≤ m + bh) || continue
            a = (col - m - 1) ÷ sq
            b = (row - m - 1) ÷ sq
            isodd(a + b) && (img[1, row, col] = 0x00)
        end
        img
    end

    # Standard OpenCV pinhole + radial distortion (zero tangential), matching what `fit_model` fits.
    function project(Xo, Rmat, t, fx, fy, cx, cy, k)
        Xc = Rmat * SVector{3,Float64}(Xo) + t
        x = Xc[1] / Xc[3]
        y = Xc[2] / Xc[3]
        r2 = x^2 + y^2
        rad = 1 + k[1] * r2 + k[2] * r2^2 + k[3] * r2^3
        SVector{2,Float32}(fx * x * rad + cx, fy * y * rad + cy)
    end

    W, H = 640, 480
    fx = 1000.0
    cx, cy = 320.0, 240.0
    n_corners = (7, 6)
    objpoints = R.XYZ.(Tuple.(CartesianIndices((0:(n_corners[1] - 1), 0:(n_corners[2] - 1), 0:0))))

    # a spread of board poses (varied orientation + translation) so calibration is well-posed
    rvecs = [SVector(0.0, 0.0, 0.0), SVector(0.2, -0.1, 0.0), SVector(-0.15, 0.2, 0.05),
             SVector(0.1, 0.25, -0.1), SVector(-0.25, -0.1, 0.0), SVector(0.05, -0.2, 0.15),
             SVector(0.3, 0.0, 0.1), SVector(-0.1, -0.25, -0.05), SVector(0.18, 0.18, 0.0)]
    tvecs = [SVector(-3.0, -2.5, 16.0), SVector(-3.2, -2.0, 15.0), SVector(-2.5, -2.8, 17.0),
             SVector(-3.5, -2.5, 16.5), SVector(-2.8, -2.2, 15.5), SVector(-3.0, -3.0, 18.0),
             SVector(-3.3, -2.4, 16.0), SVector(-2.6, -2.6, 15.0), SVector(-3.1, -2.3, 17.5)]

    make_views(fy, k) = map(zip(rvecs, tvecs)) do (rv, t)
        Rmat = SMatrix{3,3,Float64}(RotationVec(rv...))
        [project(Xo, Rmat, t, fx, fy, cx, cy, k) for Xo in objpoints]
    end

    # RMS reprojection error of the fitted model against the input image points (convention-agnostic)
    function reproj_rms(res, ipss)
        sse = 0.0
        n = 0
        for (idx, ips) in enumerate(ipss)
            Rm = SMatrix{3,3,Float64}(RotationVec(res.Rs[idx]...))
            t = SVector{3,Float64}(res.ts[idx])
            for (Xo, p) in zip(objpoints, ips)
                q = project(Xo, Rm, t, res.frow, res.fcol, res.crow, res.ccol, res.k)
                sse += (q[1] - p[1])^2 + (q[2] - p[2])^2
                n += 1
            end
        end
        sqrt(sse / n)
    end

    # --- _detect_corners ----------------------------------------------------------------------

    @testset "_detect_corners" begin
        board = checkerboard(n_corners; sq = 30, m = 40)
        detected = R._detect_corners(board, n_corners)
        @test detected !== missing
        @test detected isa Matrix{R.RowCol}
        @test size(detected) == n_corners                       # one corner per inner grid point
        @test all(p -> 0 ≤ p[1] ≤ size(board, 3) && 0 ≤ p[2] ≤ size(board, 2), detected)
        @test R.checker_size_pixel(detected, n_corners) ≈ 30 atol = 0.5   # recovers the rendered square size

        # a flat (cornerless) image yields no detection
        @test R._detect_corners(fill(0x7f, 1, 120, 160), n_corners) === missing
    end

    # --- fit_model ----------------------------------------------------------------------------

    @testset "single radial coefficient round-trip" begin
        ktrue = (0.05, 0.0, 0.0)
        views = make_views(fx, ktrue)                            # aspect = 1 ⇒ fy = fx
        res = R.fit_model((W, H), objpoints, views, n_corners, 1, 1.0)
        @test res.frow ≈ fx atol = 3.0
        @test res.fcol ≈ fx atol = 3.0
        @test res.crow ≈ cx atol = 3.0
        @test res.ccol ≈ cy atol = 3.0
        @test res.k[1] ≈ ktrue[1] atol = 0.01
        @test res.k[2] == 0.0 && res.k[3] == 0.0                 # higher coeffs fixed, not garbage
        @test reproj_rms(res, views) < 0.2                       # sub-pixel fit
        @test length(res.Rs) == length(views) && length(res.ts) == length(views)
    end

    @testset "fixed aspect ratio" begin
        aspect = 1.2
        ktrue = (0.05, 0.0, 0.0)
        views = make_views(aspect * fx, ktrue)                   # fy = aspect·fx
        res = R.fit_model((W, H), objpoints, views, n_corners, 1, aspect)
        @test res.frow ≈ fx atol = 3.0
        @test res.fcol ≈ aspect * fx atol = 4.0
        @test res.fcol / res.frow ≈ aspect atol = 1e-6           # CALIB_FIX_ASPECT_RATIO holds it exactly
        @test res.crow ≈ cx atol = 3.0
        @test res.ccol ≈ cy atol = 3.0
        @test reproj_rms(res, views) < 0.2
    end

end
