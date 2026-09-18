# The replicate floor (#296): how much the report's quantities move when nothing about the rig
# changes but where, to within a pixel, each board is held. The ideal sensor is deterministic, so
# re-rendering a rig gives no replicates; jittering the board poses does. The camera stays fixed,
# because moving it would move the truth, and the supersampling offsets too: at 16×16 they have
# converged (#292), and would understate the floor.

using LinearAlgebra: dot
using Random: Xoshiro

"The seeds of the baseline rig's jittered replicates, one replicate each (#296)."
const REPLICATES = 1:10

"""
    jittered(cam::Camera, poses, seed) -> Vector{@NamedTuple{name::String, board::Board}}

`poses` (as [`board_poses`](@ref) returns them) with every board, the flat one included, shifted in
its own plane by an offset drawn uniformly from ±½ stored px along each of its axes, a pixel being
its size at the depth of the board's centre; no board is rotated. The same `seed` gives the same
offsets. A stored px is taken as `1 / cam.f` of the depth, which holds along both axes at `sar` 1,
the one rig replicates are made of.
"""
function jittered(cam::Camera, poses, seed)
    rng = Xoshiro(seed)
    return map(poses) do (; name, board)
        px = dot(board.center - cam.position, forward(cam)) / cam.f
        u, v = px * (rand(rng) - 0.5), px * (rand(rng) - 0.5)
        (; name, board = Board(board.center + u * board.e1 + v * board.e2, board.e1, board.e2))
    end
end

"""
    replicate_rows(cache_dir) -> Vector{Row}

The builder rung's rows of each of the baseline rig's [`REPLICATES`](@ref), its poses
[`jittered`](@ref) by the replicate's seed, the rig named `"baseline, replicate <seed>"`. Their
videos are cached like any rig's (see [`cached_video`](@ref)), so only the first run renders them.
The rows themselves are not cached: they measure Fromage, which changes under them.
"""
function replicate_rows(cache_dir)
    cam = Camera(BASELINE)
    return mapreduce(vcat, REPLICATES) do seed
        measure_poses("$(BASELINE.name), replicate $seed", cam, jittered(cam, board_poses(cam), seed), cache_dir)
    end
end

# which rows a floor is shared by: all but the value, and the unit, because at `sar` 1, the only
# rig replicates are made of, a display px is a stored px; and all but the seeds' aggregate, so the
# largest over a control's seeds is its floor
const FloorKey = Tuple{String, Union{Missing, String}, String, String, Union{Missing, String}, String}
floor_key(r) = FloorKey((r.rung, r.builder, r.section, r.quantity, r.split, r.statistic))

"""
    largest_values(rows) -> Dict{FloorKey, Float64}

The largest magnitude of each quantity × split × statistic over `rows` (all rigs, seeds and
aggregates), skipping rows with no value.
"""
function largest_values(rows)
    out = Dict{FloorKey, Float64}()
    for r in rows
        ismissing(r.value) && continue
        k = floor_key(r)
        out[k] = max(get(out, k, 0.0), abs(r.value))
    end
    return out
end

"""
    Floors(replicates, baseline)

What each verdict family is judged against (#296): the `total` family's floor is the largest value
across the replicates' rows (see [`replicate_rows`](@ref)); the `model` family's is the baseline
rig's own control row, the largest of its seeds for the noisy `from_extrinsic` control. Both are the
baseline's: a variant whose own floor is higher is judged against a floor too low.
"""
struct Floors
    total::Dict{FloorKey, Float64}
    model::Dict{FloorKey, Float64}
end
Floors(replicates::AbstractVector, baseline::AbstractVector) =
    Floors(largest_values(replicates), largest_values(filter(r -> r.section == "control", baseline)))
