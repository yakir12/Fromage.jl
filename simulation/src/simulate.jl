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

"The rigs a run can measure, by name. The baseline only, until the variants (#304)."
const VARIANTS = [Rig("baseline", (;))]

"""
    simulate(; results_dir, cache_dir, variants = VARIANTS) -> DataFrame

Measure each rig of `variants` through the builder rung and return the long-format report (see
[`Row`](@ref)), after writing it as `report.csv` into a new folder of `results_dir` and printing its
primary quantities. `variants` holds [`Rig`](@ref)s, or the names of rigs of [`VARIANTS`](@ref).

The folder is named for when the run started, Fromage's version and commit, the simulation's
version and Julia's version. Neither `results_dir` nor `cache_dir` (where the rendered videos are
kept, see [`cached_video`](@ref)) has a default: both belong outside the repository. A rig that
fails is recorded as a row with its exception, and the run goes on.
"""
function simulate(; results_dir, cache_dir, variants = VARIANTS)
    rigs = select_rigs(variants)
    folder = mkpath(joinpath(results_dir, stamp()))
    rows = Row[]
    for rig in rigs
        append!(rows, measure(rig, cache_dir))
    end
    report = DataFrame(rows)
    CSV.write(joinpath(folder, "report.csv"), report)
    println("report: ", folder)
    print_summary(stdout, rows)
    return report
end

select_rigs(rigs::AbstractVector{<:Rig}) = rigs
function select_rigs(names::AbstractVector{<:AbstractString})
    known = [rig.name for rig in VARIANTS]
    unknown = setdiff(names, known)
    isempty(unknown) || throw(ArgumentError("no rig named $(join(unknown, ", ")); the rigs are $(join(known, ", "))"))
    return filter(rig -> rig.name in names, VARIANTS)
end

# one rig's rows, or the one row saying why it failed
function measure(rig::Rig, cache_dir)
    rows = attempt() do
        cam = Camera(rig)
        file = cached_video(cache_dir, cam, [[p.board for p in board_poses(cam)]; nothing])
        measure_builders(rig.name, cam, file)
    end
    rows isa Failure || return rows
    ctx = (; rig = rig.name, rung = "—", builder = missing, section = "rig")
    return [row(ctx; quantity = "rig", statistic = "status", value = missing, unit = "", status = rows.status)]
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
