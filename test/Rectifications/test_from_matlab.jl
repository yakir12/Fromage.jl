# Rectification from a MATLAB Camera Calibrator .mat file (from_matlab.jl). The fixture writes
# the fields the way MATLAB does (the loader ports CameraCalibrations.jl's loadMAT, conventions
# included), using fronto-parallel pinholes (R = 0, t = (0, 0, Z)) whose geometry is known in
# closed form: at the arena plane one world unit spans f/Z pixels, so ratio = Z/f.
@testset "matlab-based Rectification" begin
    W, H = 640, 480
    f, Z = 500.0, 100.0
    matdir = mktempdir()
    function writemat(path; k = [0.0, 0.0])
        MAT.matwrite(path, Dict("cameraParams" => Dict(
            "ImageSize" => [H, W] .* 1.0,
            "K" => [f 0.0 W/2; 0.0 f H/2; 0.0 0.0 1.0],
            "RotationVectors" => zeros(2, 3),
            "TranslationVectors" => [0.0 0.0 Z; 0.0 0.0 2Z],
            "RadialDistortion" => k)))
        path
    end
    mat = writemat(joinpath(matdir, "consistent.mat"))

    @testset "fronto-parallel geometry is recovered" begin
        rect = R.Rectification("unused.mp4", 0.0, mat, 1, 1.0, missing, missing, W, H)
        @test rect.ratio ≈ Z / f                     # one world unit spans f/Z pixels
        # center defaults to the frame centre — here the principal point — so the origin sits there
        @test rect.image2real(SVector(H / 2, W / 2)) ≈ [0, 0] atol = 1e-8
        # an f/Z-pixel step along the rows is one world unit
        @test rect.image2real(SVector(H / 2 + f / Z, W / 2)) ≈ [1, 0] atol = 1e-6
        # the maps invert each other
        for q in (SVector(100.0, 120.0), SVector(300.0, 500.0))
            @test rect.real2image(rect.image2real(q)) ≈ q atol = 1e-6
        end
        @test (rect.width, rect.height) == (W, H)
    end

    @testset "extrinsic_index selects the pose" begin
        rect2 = R.Rectification("unused.mp4", 0.0, mat, 2, 1.0, missing, missing, W, H)
        @test rect2.ratio ≈ 2Z / f                   # the second pose sits twice as far away
    end

    @testset "radial distortion from the file round-trips" begin
        matk = writemat(joinpath(matdir, "distorted.mat"); k = [0.1, 0.0])
        rect = R.Rectification("unused.mp4", 0.0, matk, 1, 1.0, missing, missing, W, H)
        for q in (SVector(100.0, 120.0), SVector(300.0, 500.0))
            @test rect.real2image(rect.image2real(q)) ≈ q atol = 1e-6
        end
    end

    @testset "center/north define a rigid reference frame" begin
        rect = R.Rectification("unused.mp4", 0.0, mat, 1, 1.0, SVector(320.0, 240.0), SVector(320.0, 100.0), W, H)
        p0 = SVector(100.0, 120.0)
        # centering + northing is rigid: a one-pixel step still spans Z/f world units
        @test norm(rect.image2real(p0 + SVector(1.0, 0.0)) - rect.image2real(p0)) ≈ Z / f atol = 1e-6
    end
end
