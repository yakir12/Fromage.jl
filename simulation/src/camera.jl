# The simulation's camera model: pinhole + radial (`k1`, `k2`, `k3`), independent of Fromage and of
# OpenCV, which checks it only as a test oracle (#282). Ported from the projection code of
# `prototype/baseline-rig:prototype/baseline_rig.jl` (#291).
#
# Conventions. World in metres. Pixels are 0-based with centres on integers (OpenCV's). The optics
# are specified in display px; a stored pixel's column is its display x / `sar`. A stored point is
# `(row, col)` and a display point `(x, y)`, as in Fromage's CONTEXT.md. The camera space is
# OpenCV's: x right, y down, z forward.

using LinearAlgebra: cross, dot, norm, normalize
using StaticArrays: SMatrix, SVector

"""
The display frame, `(width, height)` in display px, that a `Camera`'s optics are specified in: the
frame at `sar ≥ 1`. At `sar < 1` Fromage displays a smaller frame (stored 1920×540 at `sar` ½ shows
as 960×540, #293), and the optics scale with it, so the field of view stays fixed.
"""
const NOMINAL_DISPLAY = (1920, 1080)

"""
The largest undistorted normalised radius (`tan` of the angle off the optical axis, ≈ 83°) either
direction of the model accepts when the lens has no fold closer in. It bounds the bisection's
bracket; no rig looks that far off axis.
"""
const MAX_RADIUS = 8.0

"""
    Camera(; position, target, f, principal_point, k, sar)

A camera at `position` (world, m) whose optical axis passes through `target`, with image "down"
the projection of world −z. `f` (px) and `principal_point` (0-based display `(x, y)`, px) are given
in the [`NOMINAL_DISPLAY`](@ref) frame and scaled by `min(sar, 1)` into this `sar`'s display
frame. `k` holds the radial coefficients `(k1, k2, k3)` of `1 + k1 r² + k2 r⁴ + k3 r⁶`, and `sar`
is the sample aspect ratio.

The scaling multiplies the 0-based principal point, as the prototype's `DSCALE` did (#291), rather
than the pixel edges; at `sar` ½ that places it a quarter of a display pixel from where scaling the
edges would. Each rig's truth is its own camera, so this moves no comparison.

The stored frame follows `sar` as real formats do: `sar > 1` narrows the stored width, `sar < 1`
the stored height.
"""
struct Camera
    sar::Rational{Int}
    "stored width, px"
    width::Int
    "stored height, px"
    height::Int
    position::SVector{3, Float64}
    "world → camera"
    rotation::SMatrix{3, 3, Float64, 9}
    "focal length in this `sar`'s display frame, px"
    f::Float64
    "0-based display `(x, y)` in this `sar`'s display frame, px"
    principal_point::SVector{2, Float64}
    k::NTuple{3, Float64}
    "the largest undistorted normalised radius the model accepts: the fold, or `MAX_RADIUS`"
    max_radius::Float64
end

# `sar` is exact, as a real format's is: a float would convert to a rational whose huge terms
# overflow against an integer pixel in `ray`.
function Camera(; position, target, f, principal_point, k, sar::Union{Integer, Rational{<:Integer}})
    f > 0 || throw(ArgumentError("f must be positive, got $f"))
    all(isfinite, k) || throw(ArgumentError("k must be finite, got $k"))
    sar > 0 || throw(ArgumentError("sar must be positive, got $sar"))
    width, height = sar ≥ 1 ? (round(Int, NOMINAL_DISPLAY[1] / sar), NOMINAL_DISPLAY[2]) :
        (NOMINAL_DISPLAY[1], round(Int, NOMINAL_DISPLAY[2] * sar))
    scale = min(float(sar), 1.0)
    rotation = look_at(SVector{3, Float64}(position), SVector{3, Float64}(target))
    k = NTuple{3, Float64}(k)
    return Camera(
        sar, width, height, position, rotation, f * scale, scale * SVector{2, Float64}(principal_point),
        k, min(fold_radius(k), MAX_RADIUS)
    )
end

# world → camera rotation, rows right, down, forward
function look_at(position, target)
    position == target && throw(ArgumentError("position and target coincide, so the optical axis is undefined"))
    forward = normalize(target - position)
    nadir = SVector(0.0, 0.0, -1.0)
    down = nadir - dot(nadir, forward) * forward
    norm(down) > 1.0e-9 || throw(ArgumentError("the optical axis is vertical, so image down is undefined"))
    down = normalize(down)
    right = cross(down, forward)
    return vcat(right', down', forward')
end

radial(k, r²) = 1 + k[1] * r² + k[2] * r²^2 + k[3] * r²^3

# d/dr of the distorted radius r·radial(r²)
distorted_slope(k, r) = 1 + 3k[1] * r^2 + 5k[2] * r^4 + 7k[3] * r^6

"""
    fold_radius(k)

The explicit fold guard (#282): the undistorted normalised radius of the first stationary point of
`r ↦ r·radial(k, r²)`, past which the lens folds back on itself and the inverse is ambiguous; `Inf`
when there is none within `MAX_RADIUS`. Found by scanning for the first non-positive slope in
steps of `1e-3`, then bisecting that step, so a fold narrower than a step can be missed.
"""
function fold_radius(k)
    step = 1.0e-3
    for i in 1:round(Int, MAX_RADIUS / step)
        distorted_slope(k, i * step) > 0 && continue
        return bisect(r -> distorted_slope(k, r) > 0, (i - 1) * step, i * step)
    end
    return Inf
end

# the boundary in [lo, hi] between `below` holding and not, to Float64 resolution; `below(lo)` holds
function bisect(below, lo, hi)
    while true
        m = (lo + hi) / 2
        (m == lo || m == hi) && return m
        below(m) ? (lo = m) : (hi = m)
    end
    return
end

# The bracketed inverse of the radial map on its monotone branch [0, max_radius]; `nothing` past it.
# Newton steps, each one narrowing the bracket, and a bisection whenever a step would leave it (as it
# does near the fold, where the slope goes to zero); it stops when a step moves nothing. Every ray the
# renderer casts comes through here, 256 to a pixel, and bisecting to Float64 resolution alone made
# the inverse 25× the cost of tracing the ray (#299).
function undistorted_radius(cam::Camera, rd)
    lo, hi = 0.0, cam.max_radius
    rd > hi * radial(cam.k, hi^2) && return nothing
    r = min(rd, hi)
    for _ in 1:200
        g = r * radial(cam.k, r^2) - rd
        iszero(g) && return r
        g < 0 ? (lo = r) : (hi = r)
        next = r - g / distorted_slope(cam.k, r)
        lo < next < hi || (next = (lo + hi) / 2)
        (next == r || next == lo || next == hi) && return r
        r = next
    end
    return r
end

"""
    project(cam::Camera, P) -> Union{SVector{2, Float64}, Nothing}

The stored pixel `(row, col)` that world point `P` (m) projects to, or `nothing` when `P` is not in
front of the camera or lies past the lens's fold (or `MAX_RADIUS`).
"""
function project(cam::Camera, P)
    p = cam.rotation * (P - cam.position)
    p[3] > 0 || return nothing
    x, y = p[1] / p[3], p[2] / p[3]
    r² = x^2 + y^2
    r² ≤ cam.max_radius^2 || return nothing
    g = radial(cam.k, r²)
    return SVector(cam.principal_point[2] + cam.f * y * g, (cam.principal_point[1] + cam.f * x * g) / cam.sar)
end

"""
    ray(cam::Camera, pixel) -> Union{SVector{3, Float64}, Nothing}

The unit world direction from the camera through stored pixel `(row, col)`, or `nothing` when the
pixel lies past the image of the lens's fold (or of `MAX_RADIUS`) and so has no unique ray.
"""
function ray(cam::Camera, pixel)
    xd = (pixel[2] * cam.sar - cam.principal_point[1]) / cam.f
    yd = (pixel[1] - cam.principal_point[2]) / cam.f
    rd = hypot(xd, yd)
    ru = undistorted_radius(cam, rd)
    ru === nothing && return nothing
    s = iszero(rd) ? 1.0 : ru / rd
    return normalize(cam.rotation' * SVector(xd * s, yd * s, 1.0))
end
