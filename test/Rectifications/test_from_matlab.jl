# Rectification from a MATLAB Camera Calibrator .mat file (from_matlab.jl). The fixture writes
# the fields the way MATLAB does (the loader ports CameraCalibrations.jl's loadMAT, conventions
# included), using fronto-parallel pinholes (R = 0, t = (0, 0, Z)) whose geometry is known in
# closed form: at the arena plane one world unit spans f/Z pixels, so ratio = Z/f.
@testset "matlab-based rectification" begin
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
    # Every case below is this call with one field varied. Naming them is what the keyword-only
    # builder buys: the test now says which `missing` is the centre and which is the north.
    rectify(; kw...) = R.from_matlab(; file = "unused.mp4", extrinsic = 0.0, matlab_file = mat,
        extrinsic_index = 1, aspect = 1.0, center = missing, north = missing,
        width = W, height = H, kw...)

    @testset "fronto-parallel geometry is recovered" begin
        rect = rectify()
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
        rect2 = rectify(extrinsic_index = 2)
        @test rect2.ratio ≈ 2Z / f                   # the second pose sits twice as far away
    end

    @testset "radial distortion from the file round-trips" begin
        matk = writemat(joinpath(matdir, "distorted.mat"); k = [0.1, 0.0])
        rect = rectify(matlab_file = matk)
        for q in (SVector(100.0, 120.0), SVector(300.0, 500.0))
            @test rect.real2image(rect.image2real(q)) ≈ q atol = 1e-6
        end
    end

    @testset "center/north define a rigid reference frame" begin
        rect = rectify(center = SVector(320.0, 240.0), north = SVector(320.0, 100.0))
        p0 = SVector(100.0, 120.0)
        # centering + northing is rigid: a one-pixel step still spans Z/f world units
        @test norm(rect.image2real(p0 + SVector(1.0, 0.0)) - rect.image2real(p0)) ≈ Z / f atol = 1e-6
    end
end
