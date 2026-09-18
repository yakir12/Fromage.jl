# What Fromage's map is checked against (#294): where `center` and `north` put the truth, the grid the
# map is sampled on, and how an error over that grid is summarised. Ported from `map_errors`,
# `procrustes` and `stats` in `prototype/baseline-rig:prototype/baseline_rig.jl` (#291).

using LinearAlgebra: Diagonal, det, dot, norm, normalize, svd
using Statistics: mean, quantile
using StaticArrays: SVector

"""
The csv's `checker_width` (its default, #293): the board's square in cm. Fromage's real space is in
the unit of `checker_width`, so its maps come out in cm.
"""
const CHECKER_WIDTH = 100SQUARE

"Millimetres per unit of Fromage's real space."
const MM_PER_REAL = 1000SQUARE / CHECKER_WIDTH

# stored `(row, col)` ↔ display `(x, y)`, the space `center` and `north` are given in
display_point(cam::Camera, p) = SVector(p[2] * cam.sar, p[1])
stored_point(cam::Camera, q) = SVector(q[2], q[1] / cam.sar)

"""
    Gauge(cam::Camera)

Where `center` and `north` put the truth (#294). `center` is the whole display pixel nearest the
projection of the arena's middle, (0, 0), and `north` the one nearest the projection of (0, 0.5 m).
Both are back-projected through `cam` onto z = 0, and those two ground points are the truth's origin
and its +Y. Snapping to whole pixels removes the rounding the csv would otherwise add (1.2–1.9 mm,
#290) at its source; the painted dots are not moved.
"""
struct Gauge
    "`center`, whole display `(x, y)` px, as Fromage takes it"
    center::SVector{2, Float64}
    "`north`, whole display `(x, y)` px"
    north::SVector{2, Float64}
    "the truth's origin, world `(X, Y)` m"
    origin::SVector{2, Float64}
    "the truth's unit +X and +Y, world"
    x::SVector{2, Float64}
    y::SVector{2, Float64}
end

function Gauge(cam::Camera)
    snap(P) = round.(display_point(cam, something(project(cam, P))))
    center, north = snap(SVector(0.0, 0.0, 0.0)), snap(SVector(0.0, 0.5, 0.0))
    origin = ground_point(cam, stored_point(cam, center))
    y = normalize(ground_point(cam, stored_point(cam, north)) - origin)
    return Gauge(center, north, origin, SVector(y[2], -y[1]), y)
end

# where the ray through stored pixel `p` meets the ground, world `(X, Y)` m
function ground_point(cam::Camera, p)
    d = something(ray(cam, p))
    P = cam.position - cam.position[3] / d[3] * d
    return SVector(P[1], P[2])
end

"""
    truth_mm(g::Gauge, P) -> SVector{2, Float64}

Where Fromage's map should put ground point `P` (world `(X, Y)`, m), in mm: in the gauge's frame, as
Fromage's real `(y, x) = (−Y, X)` (#290).
"""
function truth_mm(g::Gauge, P)
    local_P = P - g.origin
    return 1000 * SVector(-dot(local_P, g.y), dot(local_P, g.x))
end

"The points the map is checked at: a 5 cm grid over the arena disc, world `(X, Y)` m (#294)."
const ARENA_GRID = [SVector(X, Y) for X in -1:0.05:1, Y in -1:0.05:1 if hypot(X, Y) ≤ ARENA_RADIUS]

"Whether ground point `P` (world `(X, Y)`, m) lies on the flat board's 52×40 cm footprint."
function on_flat_board(P)
    q = SVector(P[1], P[2], 0.0) - FLAT_BOARD.center
    return abs(dot(q, FLAT_BOARD.e1)) ≤ HALF_BOARD[1] && abs(dot(q, FLAT_BOARD.e2)) ≤ HALF_BOARD[2]
end

"""
    map_errors(image2real, cam::Camera, g::Gauge) -> NTuple{4, Pair{String, Vector{Float64}}}

Fromage's map `image2real` (stored `(row, col)` → real) against the truth, point by point over
[`ARENA_GRID`](@ref), each grid point seen where `cam` projects it: the distances in mm over the
whole arena, on the flat board's footprint, off it, and after the best rigid alignment (Procrustes),
which leaves the shape error without the gauge's. Each is keyed by its split's name in the report.
"""
function map_errors(image2real, cam::Camera, g::Gauge)
    got = [MM_PER_REAL * SVector{2, Float64}(image2real(something(project(cam, SVector(P[1], P[2], 0.0))))) for P in ARENA_GRID]
    truth = [truth_mm(g, P) for P in ARENA_GRID]
    e = norm.(got .- truth)
    on = on_flat_board.(ARENA_GRID)
    return ("arena" => e, "on board" => e[on], "off board" => e[.!on], "Procrustes" => procrustes(got, truth))
end

"""
    procrustes(A, B) -> Vector{Float64}

The distance from each point of `B` to its partner in `A` after the rotation and translation (no
scale, no mirror) that best align `A` onto `B`.
"""
function procrustes(A, B)
    ma, mb = mean(A), mean(B)
    U, _, V = svd(sum((a - ma) * (b - mb)' for (a, b) in zip(A, B)))
    R = V * Diagonal(SVector(1, sign(det(V * U')))) * U'
    return [norm(R * (a - ma) + mb - b) for (a, b) in zip(A, B)]
end

"The statistics each error is reported as (#294): p95 because one point at the rim can own the max."
summarize(e) = (RMS = sqrt(mean(abs2, e)), p95 = quantile(e, 0.95), max = maximum(e))
