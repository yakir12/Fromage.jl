# The baseline rig's camera and its 28 board poses, as data (#289, #291). Ported from `waved`,
# `corner` and `FLAT` in `prototype/baseline-rig:prototype/baseline_rig.jl`.
#
# The angles are frozen from the baseline rig and never adjusted per variant (#291); how close each
# board is held is fitted to the camera it is posed for.

using LinearAlgebra: cross, dot, normalize
using StaticArrays: SVector

"""
The baseline rig's camera, as `Camera` keywords: at (1.5, 0, 1.5) m aimed at the origin (45° off
nadir), no distortion, f = 900 px, principal point (971.8, 531.7) display px, 0-based, `sar` 1 —
stored 1920×1080. A variant overrides a setting: `Camera(; BASELINE_CAMERA..., sar = 2)`.
"""
const BASELINE_CAMERA = (;
    position = SVector(1.5, 0.0, 1.5), target = SVector(0.0, 0.0, 0.0),
    f = 900.0, principal_point = SVector(971.8, 531.7), k = (0.0, 0.0, 0.0), sar = 1 // 1,
)

"""
The waved board's frozen angle set, degrees (#291): about the board's vertical axis (`e2`) and about
its horizontal one (`e1`), in 10° steps; the unrotated board once, with the vertical set.
"""
const WAVED_ANGLES = (vertical = collect(-60:10:60), horizontal = [-50:10:-10; 10:10:50])

"The share of the frame's display width a corner pose's board spans before its tilt (#291)."
const CORNER_SPAN = 1 / 5

"A corner pose's tilt away from facing the camera, degrees."
const CORNER_TILT = 30

"How far inside the stored frame a posed board's outer edge stays, as a share of its display height."
const POSE_MARGIN = 0.03

# `v` rotated by θ about the unit axis `a` (Rodrigues)
rotate(v, a, θ) = v * cos(θ) + cross(a, v) * sin(θ) + a * dot(a, v) * (1 - cos(θ))

# the camera's right, down and forward axes, world
right(cam::Camera) = cam.rotation[1, :]
down(cam::Camera) = cam.rotation[2, :]
forward(cam::Camera) = cam.rotation[3, :]

# whether the board's outer edge projects at least `POSE_MARGIN` inside the stored frame
function in_frame(cam::Camera, b::Board)
    m = POSE_MARGIN * cam.height
    return all(outline(b)) do P
        p = project(cam, P)
        p !== nothing && m ≤ p[1] ≤ cam.height - 1 - m && m ≤ p[2] * cam.sar ≤ (cam.width - 1) * cam.sar - m
    end
end

# the boundary of `fits` between `bad`, where it fails, and `good`, where it holds, on the good side
function boundary(fits, bad, good)
    fits(good) && !fits(bad) || throw(ArgumentError("expected a pose that fits at $good and not at $bad"))
    for _ in 1:60
        m = (bad + good) / 2
        fits(m) ? (good = m) : (bad = m)
    end
    return good
end

# facing the camera, centred on its optical axis, rotated by `deg` about `a` (the board's own
# vertical or horizontal axis, world), and held as close to the camera as fits in frame
function waved(cam::Camera, a, deg)
    θ = deg2rad(deg)
    e1, e2 = rotate(right(cam), a, θ), rotate(down(cam), a, θ)
    pose(D) = Board(cam.position + D * forward(cam), e1, e2)
    return pose(boundary(D -> in_frame(cam, pose(D)), 0.1, 5.0))
end

# ⅕ of the frame's width, facing the camera with a 30° tilt away from the frame's centre, pushed as
# far as fits into the corner `(sx, sy)`: −1 is left or top, +1 right or bottom
function corner(cam::Camera, sx, sy)
    display_width = cam.width * cam.sar
    D = cam.f * 2HALF_BOARD[1] / (display_width * CORNER_SPAN)
    c = cam.principal_point
    function pose(s)
        r = ray(cam, SVector(c[2] + s * sy * cam.height / 2, (c[1] + s * sx * display_width / 2) / cam.sar))
        r === nothing && return nothing
        e1 = normalize(right(cam) - dot(right(cam), r) * r)
        e2 = cross(r, e1)
        τ = cross(r, normalize(sx * e1 + sy * e2))
        return Board(cam.position + D * r, rotate(e1, τ, deg2rad(CORNER_TILT)), rotate(e2, τ, deg2rad(CORNER_TILT)))
    end
    return something(pose(boundary(s -> (b = pose(s); b !== nothing && in_frame(cam, b)), 1.0, 0.0)))
end

"""
The flat (extrinsic) board: on the arena, centred at the origin, long axis along y, face up. Both
dots fall outside its footprint (±26 cm), the realistic, extrapolating case.
"""
const FLAT_BOARD = Board(SVector(0.0, 0.0, 0.0), SVector(0.0, 1.0, 0.0), SVector(1.0, 0.0, 0.0))

"""
    board_poses(cam::Camera) -> Vector{@NamedTuple{name::String, board::Board}}

The rig's 28 board poses for `cam`, in frame order: 23 waved ([`WAVED_ANGLES`](@ref)), four corner
poses (top left, top right, bottom left, bottom right) and the flat board, last. A pose's `name`
says which it is, e.g. `"waved about vertical -60°"`, `"corner top left"`, `"flat"`.
"""
function board_poses(cam::Camera)
    poses = @NamedTuple{name::String, board::Board}[]
    for (axis, a) in ((:vertical, down(cam)), (:horizontal, right(cam))), deg in WAVED_ANGLES[axis]
        push!(poses, (name = "waved about $axis $(deg)°", board = waved(cam, a, deg)))
    end
    for (sy, row) in ((-1, "top"), (1, "bottom")), (sx, col) in ((-1, "left"), (1, "right"))
        push!(poses, (name = "corner $row $col", board = corner(cam, sx, sy)))
    end
    push!(poses, (name = "flat", board = FLAT_BOARD))
    return poses
end

"""
    corner_projections(cam::Camera, b::Board) -> Matrix{SVector{2, Float64}}

The analytic projections, 0-based stored `(row, col)`, of the board's 10×7 inner corners, indexed as
[`inner_corners`](@ref). Throws when a corner does not project, which no pose of `board_poses(cam)`
allows.
"""
function corner_projections(cam::Camera, b::Board)
    return map(inner_corners(b)) do P
        p = project(cam, P)
        p === nothing && throw(ArgumentError("the board's corner at $P does not project"))
        p
    end
end
