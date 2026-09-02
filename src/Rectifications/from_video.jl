"""
    RowCol(row, col)
An alias for a static vector of two, row and column, indicating a cartesian coordinate in an image/matrix.
"""
const RowCol = SVector{2, Float32}

"""
    XYZ(x, y, z)
An alias for a static vector of three, x, y, and z, indicating a real-world coordinate. Note that `x` is equivalent to the `column` in `RowCol` and the `y` is equivalent to the `row`.
"""
const XYZ = SVector{3, <: Real}

# The ffmpeg `-vf` filter string, or `missing` when no filtering is needed. `yadif` marks interlaced
# footage: `true` ⇒ deinterlace, `false`/`missing` ⇒ progressive, leave as is. `blur` is a gblur
# sigma, where `missing` *and* `0` mean no blur (VerifyRectifications always sends a number, using 0
# as its "no blur", and a sigma-0 no-op filter must not be built). `missing` rather than `nothing`
# is the absent-value sentinel throughout, matching the structs fed into `Rectification`.
function _vf(yadif, blur)
    filters = String[]
    coalesce(yadif, false) && push!(filters, "yadif=1")
    coalesce(blur, 0) == 0 || push!(filters, "gblur=sigma=$blur")
    return isempty(filters) ? missing : join(filters, ',')
end

_cmd(file, t, ::Missing) = `$(FFMPEG.ffmpeg()) -hide_banner -loglevel error -ss $t -i $file -frames:v 1 -f rawvideo -pix_fmt gray pipe:1`
_cmd(file, t, vf) = `$(FFMPEG.ffmpeg()) -hide_banner -loglevel error -ss $t -i $file -frames:v 1 -vf $vf -f rawvideo -pix_fmt gray pipe:1`


# Read one frame off the share. Every retry in this package lives in `ShareIO`, including the one
# that used to sit here; see that module for what the share does and why this is needed at all.
_read_frame(file, t, vf) = ShareIO.capture(_cmd(file, t, vf), "ffmpeg could not read the frame at $(t)s")

function _frame_at(file, t, vf, w, h)
    buf = _read_frame(file, t, vf)
    return permutedims(reshape(buf, w, h))
end

function get_corners(file, t, vf, w, h, n_corners)
    img = _frame_at(file, t, vf, w, h)
    _detect_corners(reshape(img, 1, h, w), n_corners)
end

# The frame at `t` as a `Gray` image — the same deinterlaced/blurred frame corner detection sees.
# Used to save a failing calibration's extrinsic frame to the issues folder for inspection.
extrinsic_gray_frame(file, t, vf, w, h) = colorview(Gray, normedview(_frame_at(file, t, vf, w, h)))

function extract_intrinsics(file, start, stop, temporal_step, vf, w, h, n_corners)
    ts = start:temporal_step:stop
    corners = tmap(t -> get_corners(file, t, vf, w, h, n_corners), ts)
    collect(skipmissing(corners))
end

function obj2img(R, t, frow, fcol, crow, ccol, checker_width)
    intrinsic = AffineMap(SDiagonal(frow, fcol), SVector(crow, ccol))
    extrinsic = AffineMap(RotationVec(R...), SVector{3, Float64}(t))
    scale = LinearMap(SDiagonal{3}(I/checker_width))
    return intrinsic, extrinsic, scale
end

"""
    lens_distortion_factor(r, k)
The radial distortion factor `f(r) = 1 + k₁r² + k₂r⁴ + k₃r⁶` for up to 3 radial coefficients, so that
`lens_distortion(v, k) == v * f(|v|)`. Single source of truth shared by the forward and inverse distortion.
"""
# `evalpoly` rather than a hand-rolled accumulation: it is Base's Horner, which is both shorter and
# marginally better conditioned than summing monomials (~2.7x lower relative error at three
# coefficients; the two never differ by more than 1 ulp, and the round trip through
# `inv_lens_distortion` is bit-identical at 1.34e-11 px).
#
# This is only free because `k` is an NTuple — see the two producers, `fit_model` and `from_matlab`.
# Splatting a Vector here builds a `Tuple{Float64, Vararg{Float64}}`, which is not concrete: it
# heap-allocates and dispatches at runtime, measured at 120x per call and 15x on a full frame warp.
# A Vector `k` still WORKS, and the tests pass tuples of every length including `()`, so nothing
# breaks — it would just be slow, and silently: `test/jet.jl` runs JET's error analysis, not
# `report_opt`, so a runtime dispatch here would not turn CI red.
lens_distortion_factor(r, k) = evalpoly(r^2, (1.0, k...))

"""
    lens_distortion
Lens distortion for up to 3 radial coefficients.
"""
lens_distortion(v, k) = v * lens_distortion_factor(norm(v), k)

# End of the invertible (monotone) branch of the forward radial map g(r) = r·f(r): the smallest
# positive `r` where g'(r) = 1 + 3k₁r² + 5k₂r⁴ + 7k₃r⁶ = 0 — beyond it the distortion "folds" and
# the inverse is ill-posed. `Inf` if g is monotone everywhere (e.g. pincushion). Depends only on
# `k`, so it is computed once per calibration.
function _first_critical(k)
    h = Polynomial([1.0; [(2i + 1) * ki for (i, ki) in enumerate(k)]])   # in s = r²
    ss = roots(h)
    pos = [real(s) for s in ss if abs(imag(s)) < 1e-9 && real(s) > 1e-12]
    isempty(pos) ? Inf : sqrt(minimum(pos))
end

"""
    inv_lens_distortion(v2, k[, rstar])
Inverse radial lens distortion for up to 3 radial coefficients. Since the distortion is radial, `v` and `v2` are
collinear; we solve the scalar monotone equation `r·f(r) = |v2|` for the undistorted radius `r` by bracketed
bisection (`rstar = _first_critical(k)` is the bracket's upper bound). If `v2` lies beyond the fold (no physical
preimage — the peripheral "donut" region) the radius is clamped to the fold and a warning is issued.
"""
inv_lens_distortion(v2, k) = inv_lens_distortion(v2, k, _first_critical(k))

function inv_lens_distortion(v2, k, rstar)
    rd = norm(v2)
    rd == 0 && return SVector{2, Float64}(0.0, 0.0)
    g(r) = r * lens_distortion_factor(r, k)
    if isfinite(rstar)
        if g(rstar) < rd
            @warn "inv_lens_distortion: point beyond the invertible radius (radial distortion fold); clamping" maxlog = 1
            return SVector{2, Float64}(v2 * (rstar / rd))
        end
        a, b = 0.0, rstar
    else
        a, b = 0.0, rd
        while g(b) < rd && b < 1e8
            b *= 2
        end
    end
    for _ in 1:200
        m = (a + b) / 2
        g(m) < rd ? (a = m) : (b = m)
        b - a < 1e-14 && break
    end
    r = (a + b) / 2
    return SVector{2, Float64}(v2 * (r / rd))
end

# this is the inverse perspective map
depth(rc1, t, l) = -t/(l⋅rc1)
function get_inv_perspective_map(inv_extrinsic)
    function (rc)
        rc1 = push(rc, 1)
        t = inv_extrinsic.translation[3]
        l = inv_extrinsic.linear[end, :]
        d = depth(rc1, t, l)
        return d .* rc1
    end
end

function img2obj(intrinsic, extrinsic, scale, k)
    inv_extrinsic = inv(extrinsic)
    inv_perspective_map = get_inv_perspective_map(inv_extrinsic)
    rstar = _first_critical(k)   # depends only on k; compute once, reuse per pixel
    inv_distort(rc) = inv_lens_distortion(rc, k, rstar)
    return inv(scale), inv_extrinsic, inv_perspective_map, inv_distort, inv(intrinsic)
end

function checker_width_pixel(extrinsic_corners::AbstractMatrix, n_corners)
    s = 0.0
    for col in eachcol(extrinsic_corners)
        s += sum(norm, diff(col))
    end
    for row in eachrow(extrinsic_corners)
        s += sum(norm, diff(row))
    end
    s /= 2prod(n_corners) - sum(n_corners)
    return s
end

# The pixel coordinates being rectified have an `aspect` aspect-ratio. `center` and `north`,
# however, are read off a GUI (Gimp, Photoshop) by hand, so they are:
# 1. pixel coordinates with width first and height second, (w, h)
# 2. at an aspect ratio of 1, whatever `aspect` says
function from_video(; file, extrinsic, calibration_id, start, stop, temporal_step, yadif, blur,
        width, height, n_corners, checker_width, aspect, radial_parameters, center, north,
        rectification_diagnostics::Bool)
    vf = _vf(yadif, blur)
    intrinsic_task = Threads.@spawn extract_intrinsics(file, start, stop, temporal_step, vf, width, height, n_corners)
    extrinsic_corners = get_corners(file, extrinsic, vf, width, height, n_corners)
    # Fetched before the extrinsic frame is judged, so the spawned scan is awaited on every path out
    # of here. Throwing first left its `tmap` of ffmpeg reads running against the share after the
    # call had already failed, and dropped its exception silently — an unfetched failed Task is
    # never reported. There is nothing to cancel (Julia has no task cancellation) and nothing to
    # gain from failing sooner: the scan is bounded by the calibs window, and in the pipeline this
    # error is close to unreachable, `verify_extrinsics!` having already rejected such a row.
    imgpointss = fetch(intrinsic_task)
    ismissing(extrinsic_corners) && error("no corners detected at extrinsic time stamp")
    push!(imgpointss, extrinsic_corners)
    return _rectification(file, extrinsic, calibration_id, imgpointss, width, height, n_corners, checker_width, aspect, radial_parameters, center, north, rectification_diagnostics)
end

"""
    from_extrinsic(; file, extrinsic, yadif, blur, width, height, n_corners, checker_width, aspect, center, north)
Extrinsics-only rectification: no intrinsic-calibration window exists, so the camera pose (and
focal length) are fit from the single extrinsic frame with every lens-distortion coefficient fixed
at zero — the map is effectively the board-plane homography, disregarding lens aberrations.

Selected *solely* by the CSV row having no calibs window (both `start` and `stop` blank). Such a
row may still carry `temporal_step`/`radial_parameters`, which are then silently ignored rather
than flagged; everything else (`yadif`, `blur`, `n_corners`, `checker_width`, `aspect`, `center`,
`north`) is honoured as usual. Filling only one of the two bounds is rejected upstream. See
DESIGN-HISTORY.md for why this asymmetry is deliberate.
"""
function from_extrinsic(; file, extrinsic, yadif, blur, width, height, n_corners, checker_width,
        aspect, center, north, calibration_id, rectification_diagnostics::Bool)
    vf = _vf(yadif, blur)
    extrinsic_corners = get_corners(file, extrinsic, vf, width, height, n_corners)
    ismissing(extrinsic_corners) && error("no corners detected at extrinsic time stamp")
    return _rectification(file, extrinsic, calibration_id, [extrinsic_corners], width, height, n_corners, checker_width, aspect, 0, center, north, rectification_diagnostics)
end

# Shared tail of both constructors above: fit the camera model to the collected views (the
# extrinsic frame is always the LAST view) and compose the transform pipeline off its pose.
function _rectification(file, extrinsic, calibration_id, imgpointss, width, height, n_corners, checker_width, aspect, radial_parameters, center, north, rectification_diagnostics)
    objpoints = XYZ.(Tuple.(CartesianIndices((0:(n_corners[1] - 1), 0:(n_corners[2] - 1), 0:0))))
    # (height, width), not (width, height): every point handed to OpenCV lives in the TRANSPOSED
    # view (see `get_corners` — the frame goes in as `reshape(img, 1, h, w)` and OpenCV.jl's `Mat`
    # axes are `(channels, cols, rows)`), so coordinate 1 of a corner is its row and spans `height`.
    # `fit_model`'s `sz` is the extent of those two coordinates, in their own order.
    k, Rs, ts, frow, fcol, crow, ccol = fit_model((height, width), objpoints, imgpointss, n_corners, radial_parameters, aspect)
    extrinsic_index = length(imgpointss)
    extrinsic_corners = imgpointss[extrinsic_index]
    R = Rs[extrinsic_index]
    t = ts[extrinsic_index]
    image2real, real2image = _maps(R, t, frow, fcol, crow, ccol, k, checker_width, width, height, aspect, center, north)
    ratio = checker_width/checker_width_pixel(extrinsic_corners, n_corners)
    _diagnostic(rectification_diagnostics, file, extrinsic, calibration_id, width, height, ratio, real2image)
    return StaticRectification(image2real, real2image, ratio, width, height)
end

# Assemble the image ↔ real transform pair from one camera pose: the intrinsics
# (frow/fcol/crow/ccol), the extrinsic pose (R, t), the radial distortion k and the real-unit
# scale. Shared by the video paths above (parameters fit by fit_model) and the matlab path
# (parameters read from the .mat file; see from_matlab.jl).
function _maps(R, t, frow, fcol, crow, ccol, k, checker_width, width, height, aspect, center, north)
    intrinsic, extrinsic_transform, scale = obj2img(R, t, frow, fcol, crow, ccol, checker_width)
    distort(rc) = lens_distortion(rc, k)
    inv_scale, inv_extrinsic, inv_perspective_map, inv_distort, inv_intrinsic = img2obj(intrinsic, extrinsic_transform, scale, k)
    image2real = ∘(pop, inv_scale, inv_extrinsic, inv_perspective_map, inv_distort, inv_intrinsic)
    real2image = ∘(intrinsic, distort, PerspectiveMap(), extrinsic_transform, scale, Base.Fix2(push, 0))
    center = default_center(center, width, height, aspect)
    return add_center_north(image2real, real2image, center, north, aspect)
end
