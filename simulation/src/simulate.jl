# The entry point (#297): run each rig through the rungs, and write the report into a stamped folder.

using CSV: CSV
using DataFrames: DataFrame
using Dates: Dates, now
using Fromage: Fromage

"""
    Rig(name, settings)

A named rig: the baseline's camera ([`BASELINE_CAMERA`](@ref)) with `settings` overriding it, a
`NamedTuple` of `Camera` keywords such as `(; sar = 2 // 1)`. The objects and the pose angles are
the baseline's in every rig (#289).
"""
struct Rig{S <: NamedTuple}
    name::String
    settings::S
end

Camera(rig::Rig) = Camera(; BASELINE_CAMERA..., rig.settings...)

"The baseline rig: the baseline's camera, with no setting overridden."
const BASELINE = Rig("baseline", (;))

"The rigs a run can measure, by name. The baseline only, until the variants (#304)."
const VARIANTS = [BASELINE]

"""
    simulate(; results_dir, cache_dir, variants = VARIANTS) -> DataFrame

Measure each rig of `variants` through the builder and CSV rungs and return the long-format report (see
[`Row`](@ref)), each row with its [`Verdict`](@ref), after writing it as `report.csv` into a new
folder of `results_dir` and printing its primary quantities. `variants` holds [`Rig`](@ref)s, or the
names of rigs of [`VARIANTS`](@ref).

Every rig is judged against the baseline's floor (see [`Floors`](@ref)): its jittered
[`REPLICATES`](@ref), measured first and written beside the report as `replicates.csv`, and its own
controls, for which the baseline rig is measured even when `variants` leaves it out.

The folder is named for when the run started, Fromage's version and commit, the simulation's
version and Julia's version. Neither `results_dir` nor `cache_dir` (where the rendered videos are
kept, see [`cached_video`](@ref)) has a default: both belong outside the repository. A rig that
fails is recorded as a row with its exception, and the run goes on.
"""
function simulate(; results_dir, cache_dir, variants = VARIANTS)
    rigs = select_rigs(variants)
    folder = mkpath(joinpath(results_dir, stamp()))
    replicates = replicate_rows(cache_dir, joinpath(folder, "replicates"))
    rows = Row[]
    for rig in rigs
        append!(rows, measure(rig, cache_dir, joinpath(folder, "rigs")))
    end
    baseline = BASELINE in rigs ? filter(r -> r.rig == BASELINE.name, rows) : measure(BASELINE, cache_dir, joinpath(folder, "baseline"))
    floors = Floors(replicates, baseline)
    report = judged(rows, floors)
    CSV.write(joinpath(folder, "report.csv"), DataFrame(report))
    CSV.write(joinpath(folder, "replicates.csv"), DataFrame(judged(replicates, floors)))
    println("report: ", folder)
    print_summary(stdout, report)
    return DataFrame(report)
end

select_rigs(rigs::AbstractVector{<:Rig}) = rigs
function select_rigs(names::AbstractVector{<:AbstractString})
    known = [rig.name for rig in VARIANTS]
    unknown = setdiff(names, known)
    isempty(unknown) || throw(ArgumentError("no rig named $(join(unknown, ", ")); the rigs are $(join(known, ", "))"))
    return filter(rig -> rig.name in names, VARIANTS)
end

# one rig's rows, or the one row saying why it failed
function measure(rig::Rig, cache_dir, results_dir)
    rows = attempt() do
        cam = Camera(rig)
        measure_poses(rig.name, cam, board_poses(cam), cache_dir, results_dir)
    end
    rows isa Failure || return rows
    ctx = (; rig = rig.name, rung = "—", builder = missing, section = "rig")
    return [row(ctx; quantity = "rig", statistic = "status", value = missing, unit = "", status = rows.status)]
end

# both rungs' rows of `cam` with its boards at `poses`, their video rendered or from the cache
function measure_poses(name, cam::Camera, poses, cache_dir, results_dir; include_csv = true)
    file = cached_video(cache_dir, cam, [[p.board for p in poses]; nothing])
    inputs = rung_inputs(cam, poses, file)
    rows = measure_builders(name, cam, poses, file, inputs)
    include_csv && append!(rows, measure_csv(name, cam, poses, file, results_dir, inputs))
    return rows
end

# the run's folder name: when it started, and what ran it
function stamp()
    started = Dates.format(now(), "yyyy-mm-ddTHHMMSS")
    return "$(started)_fromage-$(pkgversion(Fromage))-$(fromage_commit())_simulation-$(pkgversion(@__MODULE__))_julia-$VERSION"
end

# Fromage's commit, `-dirty` when its tree has uncommitted changes, or `unknown` outside a git checkout
function fromage_commit()
    git(args...) = readchomp(pipeline(`git -C $(pkgdir(Fromage)) $args`; stderr = devnull))
    try
        sha = git("rev-parse", "--short=12", "HEAD")
        return isempty(git("status", "--porcelain")) ? sha : "$sha-dirty"
    catch e
        e isa Union{ProcessFailedException, Base.IOError} || rethrow()
        return "unknown"
    end
end
