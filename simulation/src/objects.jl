# The rig's objects, as geometry plus reflectance (#289): never images. The only image is the
# camera's (`render`). World in metres, z up; the ground is the plane z = 0.
#
# Surface precedence is explicit, because draw order once lost a dot (#283): the board over a dot,
# a dot over the arena, the arena over the floor.

using LinearAlgebra: cross, dot, norm
using StaticArrays: SVector

"The arena: a white disc in z = 0, centred at the origin, radius in m."
const ARENA_RADIUS = 1.0

"The two black dots painted on the arena (zero thickness): their centres, world `(X, Y)` in m."
const DOT_CENTRES = (SVector(0.0, 0.5), SVector(0.0, -0.5))

"A dot's radius, m."
const DOT_RADIUS = 0.02

"The board's checker square, m."
const SQUARE = 0.04

"The board's squares along its long and short axes; its inner corners are one fewer each way."
const SQUARES = (11, 8)

"The white margin around the board's squares, m: one square."
const MARGIN = SQUARE

# half the squares' extent along e1 and e2, and half the board's, margin included (26×20 cm)
const HALF_SQUARES = SQUARE .* SQUARES ./ 2
const HALF_BOARD = HALF_SQUARES .+ MARGIN

"""
    Surface

What a ray meets first. The last of `FLOOR`, `ARENA`, `DOT` and `BOARD` wins where they overlap;
`SKY` is a ray that meets nothing, because it leaves the ground plane without crossing the board.
"""
@enum Surface SKY FLOOR ARENA DOT BOARD

# uniform lighting and pure reflectance: no shading, no shadows (#289). The dots and the sky are
# black; the board's reflectance depends on where it is hit (`board_reflectance`).
reflectance(s::Surface) = s === FLOOR ? 0.5 : s === ARENA ? 1.0 : s === DOT || s === SKY ? 0.0 :
    throw(ArgumentError("$s has no single reflectance"))

"""
    Board(center, e1, e2)

The checkerboard: rigid and flat, 11×8 squares of 4 cm plus a one-square white margin, 52×40 cm.
`center` is its centre (world, m), `e1` the unit vector along its long axis and `e2` along its short
one; they must be orthonormal. The square at the `-e1`, `-e2` corner is black. The printed face's
outward normal is `e2 × e1`, so a board seen from the front shows `e1` to the right and `e2` down.
"""
struct Board
    center::SVector{3, Float64}
    e1::SVector{3, Float64}
    e2::SVector{3, Float64}
    function Board(center, e1, e2)
        isapprox(norm(e1), 1; atol = 1.0e-9) && isapprox(norm(e2), 1; atol = 1.0e-9) &&
            abs(dot(e1, e2)) < 1.0e-9 || throw(ArgumentError("a board's axes must be orthonormal, got $e1 and $e2"))
        return new(center, e1, e2)
    end
end

# a point on the board, at `u` along e1 and `v` along e2 from its centre (m)
on_board(b::Board, u, v) = b.center + u * b.e1 + v * b.e2

"""
    inner_corners(b::Board) -> Matrix{SVector{3, Float64}}

The board's 10×7 inner corners (world, m): `[i, j]` is the `i`th along `e1` and the `j`th along `e2`.
Their analytic projections are [`corner_projections`](@ref).
"""
inner_corners(b::Board) = [
    on_board(b, -HALF_SQUARES[1] + SQUARE * i, -HALF_SQUARES[2] + SQUARE * j)
        for i in 1:(SQUARES[1] - 1), j in 1:(SQUARES[2] - 1)
]

# points along the board's outer edge, margin included, 21 to a side: to check it is in frame
function outline(b::Board)
    t = range(-1, 1, 21)
    along_e1 = [on_board(b, x * HALF_BOARD[1], s * HALF_BOARD[2]) for x in t, s in (-1, 1)]
    along_e2 = [on_board(b, s * HALF_BOARD[1], x * HALF_BOARD[2]) for x in t, s in (-1, 1)]
    return [vec(along_e1); vec(along_e2)]
end

# the board's reflectance at `(u, v)` from its centre, or `nothing` off the board
function board_reflectance(u, v)
    (abs(u) > HALF_BOARD[1] || abs(v) > HALF_BOARD[2]) && return nothing
    (abs(u) > HALF_SQUARES[1] || abs(v) > HALF_SQUARES[2]) && return 1.0
    return iseven(floor(Int, (u + HALF_SQUARES[1]) / SQUARE) + floor(Int, (v + HALF_SQUARES[2]) / SQUARE)) ? 0.0 : 1.0
end

"""
    ground_surface(P) -> Surface

The surface at ground point `P`, world `(X, Y)` in m: a dot over the arena over the floor.
"""
function ground_surface(P)
    any(c -> norm(P - c) ≤ DOT_RADIUS, DOT_CENTRES) && return DOT
    norm(P) ≤ ARENA_RADIUS && return ARENA
    return FLOOR
end

# the distance along the unit ray to where it crosses the board, and the board's reflectance there
const MISSED = (Inf, 0.0)
board_distance(::Nothing, origin, d) = MISSED
function board_distance(b::Board, origin, d)
    n = cross(b.e1, b.e2)
    den = dot(d, n)
    abs(den) > 1.0e-12 || return MISSED
    t = dot(b.center - origin, n) / den
    t > 0 || return MISSED
    q = origin + t * d - b.center
    ρ = board_reflectance(dot(q, b.e1), dot(q, b.e2))
    return ρ === nothing ? MISSED : (t, ρ)
end

"""
    trace(board, origin, d) -> (; surface::Surface, reflectance::Float64)

The first surface the ray from `origin` (world, m) along the unit direction `d` meets, and its
reflectance there. `board` is a [`Board`](@ref), or `nothing` for a rig with no board in view.

The board wins a tie with the ground, within 1 nm along the ray: the flat board lies on the arena,
coplanar with it, and covers it.
"""
function trace(board::Union{Board, Nothing}, origin, d)
    tg = d[3] < 0 ? -origin[3] / d[3] : Inf
    tb, ρ = board_distance(board, origin, d)
    isfinite(tb) && tb ≤ tg + 1.0e-9 && return (surface = BOARD, reflectance = ρ)
    isfinite(tg) || return (surface = SKY, reflectance = reflectance(SKY))
    P = origin + tg * d
    s = ground_surface(SVector(P[1], P[2]))
    return (surface = s, reflectance = reflectance(s))
end
