# End-to-end rectification over a real video. We synthesize a calibration clip — a planar
# checkerboard at varied known poses — encode it with the bundled ffmpeg, then run the full
# `Rectification` constructor (probe → concurrent frame reads → corner detection → camera-model
# fit → transform/warp build). Success is metric: the extrinsic corners, mapped through the
# returned `image2real`, must form a regular grid whose spacing equals the real `checker_size`.
#
# Uses only the package's hard deps (FFMPEG_jll + OpenCV) — no system ffmpeg, no image libraries.

@testset "rectification (end-to-end video)" begin

    Wimg, Himg = 640, 480
    fx, cx, cy = 1000.0, 320.0, 240.0
    Kmat = SMatrix{3,3,Float64}(fx, 0, 0, 0, fx, 0, cx, cy, 1)   # [[fx 0 cx];[0 fy cy];[0 0 1]]
    n_corners = (7, 6)
    checker_size = 25.0

    # Render a planar board at pose (rv, t) exactly: it is the homography H = K·[r1 r2 t] of the
    # board plane. We rasterize by inverse-mapping each pixel and evaluating the square parity.
    function render_frame(rv, t)
        Rm = SMatrix{3,3,Float64}(RotationVec(rv...))
        H = Kmat * hcat(Rm[:, 1], Rm[:, 2], SVector{3,Float64}(t))
        Hinv = inv(H)
        img = fill(0xff, Himg, Wimg)
        nx, ny = n_corners
        for r in 1:Himg, c in 1:Wimg
            w = Hinv * SVector(Float64(c - 1), Float64(r - 1), 1.0)
            X = w[1] / w[3]
            Y = w[2] / w[3]
            (-1 ≤ X ≤ nx && -1 ≤ Y ≤ ny) || continue            # outside the board ⇒ white
            isodd(floor(Int, X) + floor(Int, Y)) && (img[r, c] = 0x00)
        end
        img
    end

    # 12 varied poses for a well-posed calibration, + 2 trailing padding frames so the extrinsic
    # timestamp (frame 11) is never at end-of-stream (ffmpeg input-seek at EOF is unreliable).
    poses = [(SVector(0.0, 0.0, 0.0), SVector(-3.0, -2.5, 16.0)),
             (SVector(0.22, -0.12, 0.0), SVector(-3.2, -2.0, 15.0)),
             (SVector(-0.16, 0.2, 0.05), SVector(-2.5, -2.8, 17.0)),
             (SVector(0.12, 0.26, -0.1), SVector(-3.5, -2.5, 16.5)),
             (SVector(-0.26, -0.12, 0.0), SVector(-2.8, -2.2, 15.5)),
             (SVector(0.06, -0.22, 0.16), SVector(-3.0, -3.0, 18.0)),
             (SVector(0.3, 0.0, 0.1), SVector(-3.3, -2.4, 16.0)),
             (SVector(-0.12, -0.26, -0.05), SVector(-2.6, -2.6, 15.0)),
             (SVector(0.19, 0.19, 0.0), SVector(-3.1, -2.3, 17.5)),
             (SVector(-0.2, 0.1, 0.08), SVector(-2.9, -2.7, 16.2)),
             (SVector(0.1, -0.18, -0.06), SVector(-3.2, -2.6, 16.8)),
             (SVector(-0.08, 0.22, 0.0), SVector(-2.7, -2.4, 15.8)),
             (SVector(0.05, -0.05, 0.0), SVector(-3.0, -2.5, 16.0)),
             (SVector(-0.1, 0.1, 0.0), SVector(-3.0, -2.5, 16.0))]

    mktempdir() do dir
        # write frames as concatenated raw gray bytes (row-major, matching _frame_at), then encode
        raw = joinpath(dir, "frames.gray")
        open(raw, "w") do io
            for (rv, t) in poses
                fr = render_frame(rv, t)
                write(io, UInt8[fr[r, c] for r in 1:Himg for c in 1:Wimg])
            end
        end
        vid = joinpath(dir, "board.mp4")
        run(`$(R.FFMPEG.ffmpeg()) -y -hide_banner -loglevel error -framerate 10 -f rawvideo -pix_fmt gray -s $(Wimg)x$(Himg) -i $raw -c:v libx264 -crf 0 -pix_fmt yuv420p $vid`)

        # frames 0..10 (t = 0.05..1.05) drive the intrinsics; frame 11 (t = 1.15) is the extrinsic
        extrinsic_t, start, stop, step = 1.15, 0.05, 1.05, 0.1
        common = (extrinsic_t, start, stop, step, missing, missing, Wimg, Himg,
                  n_corners, checker_size, 1.0, 1)

        @testset "_probe" begin
            w, h, yadif = R._probe(vid)
            @test (w, h) == (Wimg, Himg)
            @test yadif === missing            # progressive clip ⇒ no deinterlace
        end

        diag = mktempdir()
        # center = missing ⇒ defaults to the frame centre (the intended behaviour)
        rect = R.Rectification(vid, common..., missing, missing; diagnostic = diag)
        image2real = rect.image2real
        ext_corners = R.get_corners(vid, extrinsic_t, missing, Wimg, Himg, n_corners)

        @testset "constructor output & extrinsic detection" begin
            @test image2real isa Function
            @test rect.real2image isa Function
            @test (rect.width, rect.height) == (Wimg, Himg)
            @test ext_corners !== missing
            @test size(ext_corners) == n_corners
        end

        @testset "recovers a metric grid (rectification is correct)" begin
            real_pts = map(image2real, ext_corners)
            spacing = R.checker_size_pixel(real_pts, n_corners)
            @test spacing ≈ checker_size rtol = 0.02      # within 2% of the true square size
        end

        @testset "extrinsics-only constructor (single frame, zero distortion)" begin
            # no calibs window: pose + focal fit from the extrinsic frame alone, distortion pinned
            # at zero. The rendered clip is a pure pinhole with the principal point at the frame
            # centre, so the single-view fit (which fixes the principal point there) is well-posed.
            rect0 = R.Rectification(vid, extrinsic_t, missing, missing, Wimg, Himg,
                                    n_corners, checker_size, 1.0, missing, missing)
            real_pts = map(rect0.image2real, ext_corners)
            spacing = R.checker_size_pixel(real_pts, n_corners)
            @test spacing ≈ checker_size rtol = 0.05
            @test rect0.real2image isa Function
        end

        @testset "center defaults to frame centre" begin
            # explicit frame-centre pixel must reproduce the center = missing result exactly
            i2r_explicit = R.Rectification(vid, common..., SVector(Wimg / 2, Himg / 2), missing).image2real
            @test all(a ≈ b for (a, b) in zip(map(image2real, ext_corners),
                                              map(i2r_explicit, ext_corners)))
        end

        @testset "diagnostic frame written" begin
            jpgs = filter(f -> endswith(f, ".jpg"), readdir(diag))
            @test length(jpgs) == 1
            @test filesize(joinpath(diag, only(jpgs))) > 0
        end
    end
end
