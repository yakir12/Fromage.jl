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

function _probe(file)
    s = read(`$(FFMPEG.ffprobe()) -v error -select_streams v:0 -show_entries stream=width,height,field_order -of csv=p=0 $file`, String)
    w, h, field_order = split(strip(s), ',')
    yadif = field_order ∈ ("tt", "bb", "tb", "bt") ? true : missing
    return (parse(Int, w), parse(Int, h), yadif)
end

# `yadif` marks interlaced footage: `true` ⇒ deinterlace, `false`/`missing` ⇒ progressive, leave as
# is. `blur` is a gblur sigma; `missing` *and* `0` mean no blur (VerifyRectifications always sends a
# number, with 0 as its "no blur", so a sigma-0 no-op filter must not be built). Returns the ffmpeg
# `-vf` filter string, or `missing` when no filtering is needed. `missing` (not `nothing`) is the
# absent-value sentinel for every optional here, matching the structs VerifyRectifications feeds into
# `Rectification`.
function _vf(yadif, blur)
    filters = String[]
    coalesce(yadif, false) && push!(filters, "yadif=1")
    coalesce(blur, 0) == 0 || push!(filters, "gblur=sigma=$blur")
    return isempty(filters) ? missing : join(filters, ',')
end

_cmd(file, t, ::Missing) = `$(FFMPEG.ffmpeg()) -hide_banner -loglevel error -ss $t -i $file -frames:v 1 -f rawvideo -pix_fmt gray pipe:1`
_cmd(file, t, vf) = `$(FFMPEG.ffmpeg()) -hide_banner -loglevel error -ss $t -i $file -frames:v 1 -vf $vf -f rawvideo -pix_fmt gray pipe:1`


# Read one frame, retrying transient failures. EAGAIN ("Resource temporarily unavailable") from
# the CIFS share is transient by definition, so a few backoff retries ride out residual blips even
# under the concurrency limit. A persistent failure still rethrows after the last try.
function _read_frame(cmd; tries = 4)
    for i in 1:tries
        try
            return read(cmd)
        catch e
            i == tries && rethrow()
            sleep(0.2 * 2^(i - 1))          # 0.2s, 0.4s, 0.8s backoff
        end
    end
end

function _frame_at(file, t, vf, w, h)
    cmd = _cmd(file, t, vf)
    buf = Base.acquire(() -> _read_frame(cmd), READ_SEM[])   # bound concurrent opens against the share
    return permutedims(reshape(buf, w, h))
end

function get_corners(file, t, vf, w, h, n_corners)
    img = _frame_at(file, t, vf, w, h)
    _detect_corners(reshape(img, 1, h, w), n_corners)
end

function extract_intrinsics(file, start, stop, temporal_step, vf, w, h, n_corners)
    ts = start:temporal_step:stop
    corners = tmap(t -> get_corners(file, t, vf, w, h, n_corners), ts)
    collect(skipmissing(corners))
end

function obj2img(R, t, frow, fcol, crow, ccol, checker_size)
    intrinsic = AffineMap(SDiagonal(frow, fcol), SVector(crow, ccol))
    extrinsic = AffineMap(RotationVec(R...), SVector{3, Float64}(t))
    scale = LinearMap(SDiagonal{3}(I/checker_size))
    return intrinsic, extrinsic, scale
end

"""
    lens_distortion_factor(r, k)
The radial distortion factor `f(r) = 1 + k₁r² + k₂r⁴ + k₃r⁶` for up to 3 radial coefficients, so that
`lens_distortion(v, k) == v * f(|v|)`. Single source of truth shared by the forward and inverse distortion.
"""
function lens_distortion_factor(r, k)
    f = 1.0
    r2p = 1.0
    for ki in k
        r2p *= r^2
        f += ki * r2p
    end
    return f
end

"""
    lens_distortion
Lens distortion for up to 3 radial coefficients.
"""
lens_distortion(v, k) = v * lens_distortion_factor(norm(v), k)

# End of the invertible (monotone) branch of the forward radial map g(r) = r·f(r): the smallest positive `r` where
# g'(r) = 1 + 3k₁r² + 5k₂r⁴ + 7k₃r⁶ = 0 (beyond it the distortion "folds" and the inverse is ill-posed). `Inf` if
# g is monotone everywhere (e.g. pincushion). Depends only on `k`, so compute once per calibration.
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

# this is the inverse prespective map
depth(rc1, t, l) = -t/(l⋅rc1)
function get_inv_prespective_map(inv_extrinsic)
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
    inv_perspective_map = get_inv_prespective_map(inv_extrinsic)
    rstar = _first_critical(k)   # depends only on k; compute once, reuse per pixel
    inv_distort(rc) = inv_lens_distortion(rc, k, rstar)
    return inv(scale), inv_extrinsic, inv_perspective_map, inv_distort, inv(intrinsic)
end

function checker_size_pixel(extrinsic_corners, n_corners)
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

# Rectification assumes that the pixel coodrinates it rectifies have a `aspect` aspect-ratio. 
# `center` and `north` are assumed to have been manually retrieved (from some GUI like Gimp or Photoshop) and as such:
# 1. pixel coordinates with width first and height second, (w, h)
# 2. their aspect ratio is 1, regardless of the aspect ratio specified by `aspect`
function Rectification(file, extrinsic, start, stop, temporal_step, yadif, blur, width, height, n_corners, checker_size, aspect, radial_parameters, center, north; diagnostic = nothing)
    vf = _vf(yadif, blur)
    intrinsic_task = Threads.@spawn extract_intrinsics(file, start, stop, temporal_step, vf, width, height, n_corners)
    extrinsic_corners = get_corners(file, extrinsic, vf, width, height, n_corners)
    ismissing(extrinsic_corners) && error("no corners detected at extrinsic time stamp")
    imgpointss = fetch(intrinsic_task)
    push!(imgpointss, extrinsic_corners)
    return _rectification(file, extrinsic, imgpointss, width, height, n_corners, checker_size, aspect, radial_parameters, center, north, diagnostic)
end

"""
    Rectification(file, extrinsic, yadif, blur, width, height, n_corners, checker_size, aspect, center, north)
Extrinsics-only rectification: no intrinsic-calibration window exists, so the camera pose (and
focal length) are fit from the single extrinsic frame with every lens-distortion coefficient fixed
at zero — the map is effectively the board-plane homography, disregarding lens aberrations.

# Design note: selected by the absence of the calibs window, never flagged

Which constructor a rectification gets is decided *solely* by whether the CSV row has a calibs
window: both `start` and `stop` blank ⇒ this single-frame fit. A row that omits the
window but still fills the intrinsic-window parameters (`temporal_step`, `radial_parameters`) is
NOT flagged as inconsistent — those two parameters are silently ignored (they only make sense when
a window of frames is sampled; everything else — `yadif`, `blur`, `n_corners`, `checker_size`,
`aspect`, `center`, `north` — is honored as usual).

We chose this simplification deliberately. Leaving *both* window time stamps out of a row is too
large an "action" to plausibly happen by mistake — the user must have intended an extrinsics-only
rectification — so stray leftover parameters shouldn't override that intent with an error (unlike a
filled column that belongs to a different `type`, which VerifyRectifications does flag). Filling only
one of the two bounds is still rejected upstream ("both present or both missing").
"""
function Rectification(file, extrinsic, yadif, blur, width, height, n_corners, checker_size, aspect, center, north; diagnostic = nothing)
    vf = _vf(yadif, blur)
    extrinsic_corners = get_corners(file, extrinsic, vf, width, height, n_corners)
    ismissing(extrinsic_corners) && error("no corners detected at extrinsic time stamp")
    return _rectification(file, extrinsic, [extrinsic_corners], width, height, n_corners, checker_size, aspect, 0, center, north, diagnostic)
end

# Shared tail of both constructors above: fit the camera model to the collected views (the
# extrinsic frame is always the LAST view) and compose the transform pipeline off its pose.
function _rectification(file, extrinsic, imgpointss, width, height, n_corners, checker_size, aspect, radial_parameters, center, north, diagnostic)
    objpoints = XYZ.(Tuple.(CartesianIndices((0:(n_corners[1] - 1), 0:(n_corners[2] - 1), 0:0))))
    k, Rs, ts, frow, fcol, crow, ccol = fit_model((width, height), objpoints, imgpointss, n_corners, radial_parameters, aspect)
    extrinsic_index = length(imgpointss)
    extrinsic_corners = imgpointss[extrinsic_index]
    R = Rs[extrinsic_index]
    t = ts[extrinsic_index]
    intrinsic, extrinsic_transform, scale = obj2img(R, t, frow, fcol, crow, ccol, checker_size)
    distort(rc) = lens_distortion(rc, k)
    inv_scale, inv_extrinsic, inv_perspective_map, inv_distort, inv_intrinsic = img2obj(intrinsic, extrinsic_transform, scale, k)
    image2real = ∘(pop, inv_scale, inv_extrinsic, inv_perspective_map, inv_distort, inv_intrinsic)
    real2image = ∘(intrinsic, distort, PerspectiveMap(), extrinsic_transform, scale, Base.Fix2(push, 0))
    center = default_center(center, width, height)
    image2real, real2image = add_center_north(image2real, real2image, center, north, aspect)

    ratio = checker_size/checker_size_pixel(extrinsic_corners, n_corners)
    warp_trans = get_warp(ratio, real2image)
    if !isnothing(diagnostic)
        imgw = warp_extrinsic(file, extrinsic, width, height, warp_trans)
        FileIO.save(joinpath(diagnostic, string(first(splitext(basename(file))), "_$extrinsic.jpg")), parent(imgw))
    end
    return (; image2real, real2image, ratio, width, height)
end
