# Rectification from a MATLAB Camera Calibrator `.mat` file: the camera model — intrinsics (K),
# radial distortion, and the extrinsic pose selected by `extrinsic_index` — is read from the file
# instead of being fit from a checkerboard video. The extraction (including the MATLAB axis and
# angle conventions) is ported untouched from CameraCalibrations.jl's `loadMAT`. Real-world
# coordinates come out in the `.mat`'s own world units (whatever square size the MATLAB
# calibration was given), so the unit scale is 1.
function Rectification(file, extrinsic, matlab_file, extrinsic_index, aspect, center, north, width, height; diagnostic = nothing)
    dict = matread(matlab_file)
    # the Camera Calibrator wraps everything in a single top-level struct (e.g. "cameraParams");
    # unwrap until the calibration fields are at hand (VerifyRectifications already verified they
    # exist, nested or not)
    while !haskey(dict, "K") && length(keys(dict)) == 1 && first(values(dict)) isa AbstractDict
        dict = first(values(dict))
    end

    fcol = dict["K"][1, 1]
    frow = dict["K"][2, 2]
    ccol = dict["K"][1, 3]
    crow = dict["K"][2, 3]

    # both of these have their x and y the other way around, due to some matlab convention
    R = -Vector{Float64}(dict["RotationVectors"][extrinsic_index, [2, 1, 3]])   # negative due to some matlab angle convention...
    t = Vector{Float64}(dict["TranslationVectors"][extrinsic_index, [2, 1, 3]])

    k = vec(dict["RadialDistortion"])

    image2real, real2image = _maps(R, t, frow, fcol, crow, ccol, k, 1, width, height, aspect, center, north)
    # units-per-pixel at the arena centre — the matlab analogue of the video path's
    # checker_size/checker_size_pixel (there are no detected corners to measure it from): one
    # real-world unit step at the origin spans 1/ratio pixels
    ratio = 1 / norm(real2image(SVector(1.0, 0.0)) - real2image(SVector(0.0, 0.0)))
    _diagnostic(diagnostic, file, extrinsic, width, height, ratio, real2image)
    return (; image2real, real2image, ratio, width, height)
end
