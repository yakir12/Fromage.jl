# The replicate floor (#296, #312): how much the report's quantities move when nothing about the
# rig changes but where, to within a pixel, each board is held. The ideal sensor is deterministic,
# so re-rendering a rig gives no replicates; jittering the board poses does. The camera stays fixed,
# because moving it would move the truth, and the supersampling offsets too: at 16×16 they have
# converged (#292), and would understate the floor.
#
# A quantity's floor is that movement, its spread; the value it moves about is the baseline's level.
# The two differ most where the baseline is systematically wrong: `from_extrinsic` fixes the
# principal point and every distortion coefficient, so its map is ~2.7 mm off at the baseline and
# moves by ~0.23 mm. A verdict asks how far a row is above the level, in floors (see `judge`).

using LinearAlgebra: dot
using Random: Xoshiro
using Statistics: median

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
The CSV rows reuse those measurements: the gateway is exercised for real rigs, while the replicate
floor only needs the same rung-shaped values for both report families.
The rows themselves are not cached: they measure Fromage, which changes under them.
"""
function replicate_rows(cache_dir, results_dir)
    cam = Camera(BASELINE)
    return mapreduce(vcat, REPLICATES) do seed
        @info "Measuring baseline replicate" seed
        builders = measure_poses(
            "$(BASELINE.name), replicate $seed", cam, jittered(cam, board_poses(cam), seed), cache_dir,
            results_dir, BASELINE.radial_parameters; include_csv = false,
        )
        csv = [merge(r, (; rung = "csv")) for r in builders]
        [builders; csv]
    end
end

# which rows a level and floor are shared by: all but the value, and the seeds' aggregate, so a
# control's floor spans its seeds as well as the jitter. The unit is in the key (#313), and that
# costs the display-px `corners` rows a `sar ≠ 1` rig adds their floor: the replicates are at `sar` 1
# and emit none, so those rows keep their value but are judged `n/a`. Borrowing the stored-px floor
# instead would be off by a factor up to `sar`, and scaling it by `sar` would assume the isotropic
# detector error that the display-px row is there to question (#294).
const FloorKey = Tuple{String, Union{Missing, String}, String, String, Union{Missing, String}, String, String}
floor_key(r) = FloorKey((r.rung, r.builder, r.section, r.quantity, r.split, r.statistic, r.unit))

"A quantity's baseline `level`, the median of its magnitudes, and its `floor`, their range."
const Level = @NamedTuple{level::Float64, floor::Float64}

"""
    levels(rows) -> Dict{FloorKey, Level}

The [`Level`](@ref) of each quantity × split × statistic × unit over `rows` (all rigs, seeds and
aggregates), skipping rows with no value. Magnitudes, so a signed error cannot hide a large one
behind a small median; the range, rather than a standard deviation, assumes no distribution of ten
samples (#296).
"""
function levels(rows)
    magnitudes = Dict{FloorKey, Vector{Float64}}()
    for r in rows
        ismissing(r.value) && continue
        push!(get!(magnitudes, floor_key(r), Float64[]), abs(r.value))
    end
    return Dict{FloorKey, Level}(k => Level((median(v), maximum(v) - minimum(v))) for (k, v) in magnitudes)
end

"""
    Floors(replicates, baseline)

What each verdict family is judged against (#296, #312), as a [`Level`](@ref) per quantity: the
`total` family's over the replicates' rows (see [`replicate_rows`](@ref)); the `model` family's over
the analytic-corner controls of the replicates and of the baseline rig, every seed of the noisy
`from_extrinsic` control included. Both are the baseline's: a variant whose own floor is higher is
judged against a floor too low.
"""
struct Floors
    total::Dict{FloorKey, Level}
    model::Dict{FloorKey, Level}
end
function Floors(replicates::AbstractVector, baseline::AbstractVector)
    controls = filter(r -> r.section == "control", [replicates; baseline])
    return Floors(levels(replicates), levels(controls))
end
