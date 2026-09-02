"""
    _detect_corners
Wraps OpenCV function to auto-detect corners in an image.
"""
function _detect_corners(img, n_corners)
    gry = OpenCV.Mat(img)
    corners = Matrix{RowCol}(undef, n_corners)
    flags = OpenCV.CALIB_CB_ADAPTIVE_THRESH + OpenCV.CALIB_CB_NORMALIZE_IMAGE + OpenCV.CALIB_CB_FAST_CHECK
    ret, _ = OpenCV.findChessboardCorners(gry, OpenCV.Size{Int32}(n_corners...),
                                          OpenCV.Mat(reshape(reinterpret(Float32, corners), 2, 1, prod(n_corners))),
                                          flags)
    return ret ? corners : missing
end

"""
    fit_model
Wraps OpenCV function to fit a camera model to given object and image points.

`sz` is the extent of the image points' two coordinates, in the order the points carry them —
`(height, width)` for the transposed view everything here works in (see `_detect_corners`). It
reaches OpenCV as `imageSize`, which seeds the principal point at its centre; with a single view
that seed is also the answer, since `CALIB_FIX_PRINCIPAL_POINT` pins it there. Passing it the
other way round therefore fits the extrinsics-only rectification around a principal point
reflected across the frame diagonal.
"""
function fit_model(sz, objpoints, imgpointss, n_corners, radial_parameters, aspect)
    cammat = convert(Matrix{Float64}, I(3))
    cammat[2, 2] = aspect
    dist = Vector{Float64}(undef, 5)
    nfiles = length(imgpointss)
    r = [Vector{Float64}(undef, 3) for _ in 1:nfiles]
    t = [Vector{Float64}(undef, 3) for _ in 1:nfiles]
    # radial_parameters = 0 fixes ALL radial coefficients at zero (distortionless fit, used by the
    # extrinsics-only Rectification): setdiff(1:3, 1:0) selects every CALIB_FIX_K.
    CALIB_FIX_K = sum([OpenCV.CALIB_FIX_K1, OpenCV.CALIB_FIX_K2, OpenCV.CALIB_FIX_K3][setdiff(1:3, 1:radial_parameters)])
    flags = OpenCV.CALIB_ZERO_TANGENT_DIST + CALIB_FIX_K + OpenCV.CALIB_FIX_ASPECT_RATIO
    # a single planar view leaves focal + principal point + pose underdetermined by one DOF; fixing
    # the principal point (at the image centre, OpenCV's default without an intrinsic guess) makes
    # the single-frame fit well-posed
    nfiles == 1 && (flags += OpenCV.CALIB_FIX_PRINCIPAL_POINT)

    OpenCV.calibrateCamera(OpenCV.InputArray[Float32.(reshape(stack(objpoints), 3, 1, :)) for _ in 1:nfiles],
                                                         OpenCV.InputArray[Float32.(reshape(stack(imgpoints), 2, 1, :)) for imgpoints in imgpointss],
                                                         OpenCV.Size{Int32}(sz...),
                                                         OpenCV.Mat(reshape(cammat, 1, 3, 3)),
                                                         OpenCV.Mat(reshape(dist, 1, 1, 5)),
                                                         OpenCV.InputArray[OpenCV.Mat(reshape(ri, 1, 1, 3)) for ri in r],
                                                         OpenCV.InputArray[OpenCV.Mat(reshape(ti, 1, 1, 3)) for ti in t], flags, CRITERIA)
    # `k` as an NTuple, not a Vector: it is a fixed-length model parameter, and the concrete type
    # is what lets `lens_distortion_factor`'s `evalpoly` unroll without allocating. `dist` always
    # holds all three radial slots — `radial_parameters < 3` fixes the unfitted ones at zero rather
    # than omitting them (see CALIB_FIX_K above).
    return (k = (dist[1], dist[2], dist[5]), Rs = r, ts = t, frow = cammat[1,1], fcol = cammat[2,2], crow = cammat[3,1], ccol = cammat[3,2])
end
