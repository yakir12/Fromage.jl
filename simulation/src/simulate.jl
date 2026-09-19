# The entry point (#297): run each rig through the rungs, and write the report into a stamped folder.

using CSV: CSV
using DataFrames: DataFrame
using Dates: Dates, now
using Fromage: Fromage

"""
    Rig(name, settings; radial_parameters = 1)

A named rig: the baseline's camera ([`BASELINE_CAMERA`](@ref)) with `settings` overriding it, a
`NamedTuple` of `Camera` keywords such as `(; sar = 2 // 1)`. The objects and the pose angles are
the baseline's in every rig (#289). `radial_parameters` is the number of radial coefficients
Fromage fits, independently of the camera's true `k`; it applies to both rungs and their
checkerboard controls. The extrinsics-only builder always fits zero.
"""
struct Rig{S <: NamedTuple}
    name::String
    settings::S
    radial_parameters::Int
end

Rig(name, settings; radial_parameters = RADIAL_PARAMETERS) = Rig(name, settings, radial_parameters)

Camera(rig::Rig) = Camera(; BASELINE_CAMERA..., rig.settings...)

"The baseline rig: the baseline's camera, with no setting overridden."
const BASELINE = Rig("baseline", (;))

"""
The 32 named rigs of #304: baseline, five `sar`s, four single-`k1` lenses, one two-term lens
fitted at orders 2 and 1, and the full 20-cell `sar` × `k1` grid. The two-term lens is
`(-0.25, 0.08, 0)`, already exercised by the camera's OpenCV oracle; its two fits share a video.
Names use rational `sar` components (`"sar_64_45"`) and signed coefficients (`"k1_-0.15"`).
"""
const VARIANTS = let
    sars = (1 // 2, 10 // 11, 16 // 15, 64 // 45, 2 // 1)
    k1s = (-0.05, -0.15, -0.3, 0.05)
    sar_name(sar) = "sar_$(numerator(sar))_$(denominator(sar))"
    [
        BASELINE;
        [Rig(sar_name(sar), (; sar)) for sar in sars];
        [Rig("k1_$k1", (; k = (k1, 0.0, 0.0))) for k1 in k1s];
        [Rig("k1_k2_fit$n", (; k = (-0.25, 0.08, 0.0)); radial_parameters = n) for n in (2, 1)];
        [Rig("$(sar_name(sar))_k1_$k1", (; sar, k = (k1, 0.0, 0.0))) for sar in sars for k1 in k1s];
    ]
end

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
    for (index, rig) in enumerate(rigs)
        @info "Measuring rig" index total = length(rigs) rig = rig.name
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
        measure_poses(rig.name, cam, board_poses(cam), cache_dir, results_dir, rig.radial_parameters; include_csv = true)
    end
    rows isa Failure || return rows
    ctx = (; rig = rig.name, rung = "—", builder = missing, section = "rig")
    return [row(ctx; quantity = "rig", statistic = "status", value = missing, unit = "", status = rows.status)]
end

# both rungs' rows of `cam` with its boards at `poses`, their video rendered or from the cache
function measure_poses(name, cam::Camera, poses, cache_dir, results_dir, radial_parameters; include_csv)
    file = cached_video(cache_dir, cam, [[p.board for p in poses]; nothing])
    inputs = rung_inputs(cam, poses, file)
    rows = measure_builders(name, cam, poses, file, inputs, radial_parameters)
    include_csv && append!(rows, measure_csv(name, cam, poses, file, results_dir, inputs, radial_parameters))
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
