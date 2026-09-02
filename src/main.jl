# Every segment shares one resolution, codec and quality (see diagnose.jl), so a single ffmpeg
# concat-demuxer call stream-copies them into the final video, rewriting timestamps monotonically.
#
# Deliberately NOT routed through `ShareIO`: every path here is under `results_dir`, on local disk.
# The retries exist for the CIFS share and belong only on reads that cross it.
# ffmpeg takes each path in the list single-quoted, and a literal quote inside one is written
# `'\''` — close the string, escape the quote, reopen. An apostrophe is a legal file-name character
# and a plausible `run_id` ("beetle's run"); unescaped it closed the line early and took the segment
# with it.
concat_escape(f) = replace(f, "'" => raw"'\''")

function concatenate(path, files)
    list = joinpath(path, "list.txt")
    open(list, "w") do io
        foreach(f -> println(io, "file '", concat_escape(f), "'"), files)
    end
    out = joinpath(RESULTS_DIR, "diagnostic.mp4")
    ffmpeg_exe(` -y -loglevel error -f concat -safe 0 -i $list -c copy $out`)
end

# Save one run's track to results_dir/<run_id>.csv: one row per coordinate, with the `time` stamp
# (seconds into the video) and the `x`/`y` real-world coordinates. `track` returns coordinates the
# rectification's `image2real` has already been applied to, so the origin is at the calibration's
# `center`, north-aligned when `north` was given, in the calibration's real-world unit. Axis follows
# the image — x rightward, y downward — as `(y-direction, x-direction)`, hence the `y, x` unpack.
# A `missing` coordinate (AprilTag tracking, where a frame's target couldn't be localized) keeps its
# `time` with empty `x`/`y`, so the time axis stays intact and the gaps are explicit.
function save2csv(run_id, (ts, coords))
    open(joinpath(RESULTS_DIR, string(run_id, ".csv")), "w") do io
        println(io, "time,x,y")
        for (t, c) in zip(ts, coords)
            if ismissing(c)
                println(io, t, ",,")
            else
                y, x = c
                println(io, t, ',', x, ',', y)
            end
        end
    end
end

# Keep only the entries whose `id` field was asked for, and reject any requested id that matched
# nothing. Filtering by id is a convenience for iterating on one run or calibration, so an id that
# matches nothing is a typo rather than a request for less: every requested id must match (#21).
function filter_ids!(xs, requested, id, what)
    isnothing(requested) && return xs
    available = [getfield(x, id) for x in xs]
    unmatched = setdiff(requested, available)
    if !isempty(unmatched)
        error("unknown $id(s) in `$(what)`: $(sort(unmatched)). Available $(id)s: $(sort(available))")
    end
    return filter!(x -> getfield(x, id) ∈ requested, xs)
end

# The building entry points open the same way: make the results directory, load the csv the caller
# named, and drop everything the caller did not ask for. `load_*` builds or throws, so there is one
# return type and nothing to assert — the `isa AbstractDataFrame` test and the
# `::Vector{RectificationMethod}` assertion that used to sit here existed only because a `strict`
# keyword chose the return type at runtime (JET flags e.g. `length(::DataFrame)` otherwise).
function gather_rectifications(data_path, calibs_file, defaults, calibration_ids = nothing)
    mkpath(RESULTS_DIR)
    # `issues_dir` is left at its default, which Paths derives from `results_dir` — the frames a
    # failing calibration dumps land under the same output folder as everything else.
    cs = load_rectifications(joinpath(data_path, calibs_file); defaults)
    return filter_ids!(cs, calibration_ids, :calibration_id, "calibration_ids")
end

function gather_runs(data_path, runs_file, defaults, run_ids = nothing)
    mkpath(RESULTS_DIR)
    rs = load_runs(joinpath(data_path, runs_file); defaults)
    return filter_ids!(rs, run_ids, :run_id, "run_ids")
end

# `rectification_diagnostics` travels from here to `_diagnostic` unchanged — same name, same `Bool`
# — so there is no path assembly in between and nothing to keep in step. An `apriltag` calibration
# has no fixed image->real map to warp through and quietly produces no image; its top-down
# diagnostic is the per-run video instead.
build_rectifications(cs, rectification_diagnostics::Bool) =
    @showprogress desc = "Building rectifications" tmap(c -> Rectification(c; rectification_diagnostics), cs)

# Both csv files, validated as one dataset. The identities of BOTH are settled first — each file's
# own, then the cross-file check that they describe the same thing — before either file's videos are
# opened, so an incoherent pair costs no reads at all (#121, #122).
#
# The two loaders are driven a tier at a time rather than through `load_rectifications`/`load_runs`,
# which validate one file end to end: the cross-file check has to happen between the tiers, and it
# needs both files parsed to run at all.
#
# Both csv files, validated as one dataset, up to but not including the decision of what to do about
# what was found. Returns both annotated DataFrames and whether anything was wrong; the two callers
# below differ only in that decision, which is why the pipeline itself lives here once.
#
# The identities of BOTH files are settled first — each file's own, then the cross-file check that
# they describe the same thing — before either file's videos are opened, so an incoherent pair costs
# no reads at all (#121, #122).
#
# The two loaders are driven a tier at a time rather than through `load_rectifications`/`load_runs`,
# which validate one file end to end: the cross-file check has to happen between the tiers, and it
# needs both files parsed to run at all.
function _validate_dataset(data_path, calibs_file, runs_file, rectification_defaults, tracking_defaults)
    calibs, calibs_ids_ok = VerifyRectifications.parse_rectifications(
        data_path, joinpath(data_path, calibs_file); defaults = rectification_defaults)
    runs, runs_ids_ok = VerifyRuns.parse_runs(
        data_path, joinpath(data_path, runs_file); defaults = tracking_defaults)

    # Coherence is a property of the two files AS WRITTEN, so it is checked on all of their rows —
    # before `run_ids` narrows anything. Narrowing decides what gets built, never what gets
    # validated; otherwise asking for one run would fail the calibrations it did not ask for.
    coherent = verify_cross_references!(calibs, runs, :calibration_id, "calibs.csv", "runs.csv")

    # The first-tier gate, across both files. Both are reported before the caller decides, so a user
    # fixing a dataset sees everything the csv text can tell them in one pass rather than one file's
    # problems per run.
    tier1_bad = false
    if !(calibs_ids_ok && runs_ids_ok && coherent)
        tier1_bad = VerifyRectifications.report_calibs(calibs, false)
        tier1_bad |= VerifyRuns.report_runs(runs, false)
    end

    VerifyRectifications.verifications!(calibs, data_path, DEFAULT_ISSUES_DIR)
    VerifyRuns.verifications!(runs, data_path)

    bad = VerifyRectifications.report_calibs(calibs, false)
    bad |= VerifyRuns.report_runs(runs, false)
    return calibs, runs, (bad || tier1_bad)
end

# Build both, or throw. Always returns the two vectors.
function load_dataset(data_path, calibs_file, runs_file, rectification_defaults, tracking_defaults)
    calibs, runs, bad = _validate_dataset(data_path, calibs_file, runs_file,
                                          rectification_defaults, tracking_defaults)
    bad && error("there were issues with the data (see above)")
    return VerifyRectifications.build_methods(calibs), VerifyRuns.build_runs(runs)
end

# Validate and report, never throw. Always returns both annotated DataFrames — both, not just the
# offending one: a dataset is accepted or rejected as a whole, and runs whose calibration was
# rejected are not buildable anyway.
function check_dataset(data_path, calibs_file, runs_file, rectification_defaults, tracking_defaults)
    calibs, runs, _ = _validate_dataset(data_path, calibs_file, runs_file,
                                        rectification_defaults, tracking_defaults)
    return calibs, runs
end

"""
    main(data_path; calibs_file = "calibs.csv", runs_file = "runs.csv",
         rectification_defaults = (;), tracking_defaults = (;), run_ids = nothing,
         rectification_diagnostics = false)

Run the whole pipeline over the data folder `data_path`: validate `calibs.csv` and `runs.csv` as one
dataset, build a rectification for each calibration, track every run through the one it names, and
write the results.

Returns a `DataFrame` with one row per run, carrying `run_id`, `calibration_id`, the built
`rectification`, and `run` — the track itself, as `(timestamps, coordinates)`.

Everything produced lands under `results_dir/`, created in the folder Julia was started in: one
`<run_id>.csv` per run (a row per coordinate, with `time` in seconds into the video and `x`/`y` in
the calibration's real-world unit, origin at its `center`), and `diagnostic.mp4`.

# Keyword arguments

- `calibs_file`, `runs_file`: the two csv file names, relative to `data_path`.

- `rectification_defaults`, `tracking_defaults`: globally replace the hardcoded defaults of the
  tuning parameters, e.g. `rectification_defaults = (n_corners = (5, 8), blur = 0)` or
  `tracking_defaults = (target_width = 60,)`. The hierarchy is: csv cell → these keywords → the
  hardcoded or probed default. Each gateway whitelists what may be set (see `DEFAULTS` in the
  respective `parsers.jl`) and rejects anything else up front.

- `run_ids`: restrict processing to the named runs. Only the rectifications those runs reference
  are built. An id matching no row is an error, not a request for less (#21).

- `rectification_diagnostics`: also save each calibration's extrinsic frame, warped through the
  rectification fitted to it, to `results_dir/rectifications/<calibration_id>.jpg`. The same "are
  the straight edges straight" check the diagnostic video offers, but available as soon as the
  rectifications are built rather than after every run has been tracked. An `apriltag` calibration
  has no fixed image→real map to warp through and quietly produces no image; its top-down
  diagnostic is the per-run video instead.

Issues in either csv abort the run. To inspect a dataset instead of processing it, call [`verify`](@ref),
which reports everything wrong with both files and returns them for inspection without building
anything.

See also `only_track` and `only_rectify`, the two narrowing entry points.
"""
function main(data_path::String; calibs_file = "calibs.csv", runs_file = "runs.csv",
        rectification_defaults = (;), tracking_defaults = (;), run_ids = nothing,
        rectification_diagnostics::Bool = false)
    mkpath(RESULTS_DIR)
    cs, rs = load_dataset(data_path, calibs_file, runs_file, rectification_defaults, tracking_defaults)

    # Coherence guarantees every calibration is used, so with no `run_ids` this keeps all of them;
    # with one, it drops the calibrations the surviving runs no longer reference.
    rs = filter_ids!(rs, run_ids, :run_id, "run_ids")
    run_calib_ids = [r.calibration_id for r in rs]
    filter!(c -> c.calibration_id ∈ run_calib_ids, cs)

    calib_ids = [c.calibration_id for c in cs]
    calibs = DataFrame(calibration_id = calib_ids, c = cs)

    calibs.rectification .= build_rectifications(calibs.c, rectification_diagnostics)

    runs = DataFrame(calibration_id = [r.calibration_id for r in rs], run_id = [r.run_id for r in rs], r = rs)
    leftjoin!(runs, calibs, on = :calibration_id)

    mktempdir() do path
        transform!(runs, :run_id => (x -> joinpath.(path, string.(x, ".mp4"))) => :diagnostic_file)
        build_run(r, c, rectification, diagnostic_file) =
            track(r, c.source.center, rectification, diagnostic_file)
        runs.run .= @showprogress desc = "Building runs" tmap(
            build_run, runs.r, runs.c, runs.rectification, runs.diagnostic_file)
        concatenate(path, runs.diagnostic_file)
        select!(runs, Not(:diagnostic_file))
    end

    tforeach(save2csv, runs.run_id, runs.run)

    return runs
end

# Each diagnostic is named by its run's `run_id`, as in `main` — which is the row number when the
# csv names no runs, and the run's own name when it does. Numbering by position instead would
# rename every file as soon as `run_ids` filtered one out.
"""
    verify(data_path; calibs_file = "calibs.csv", runs_file = "runs.csv",
           rectification_defaults = (;), tracking_defaults = (;))

Validate `calibs.csv` and `runs.csv` in `data_path` as one dataset and report everything wrong with
them, **without building or tracking anything**. For looking at a dataset rather than processing it;
[`main`](@ref) is the one that does the work and aborts on any issue.

Returns `(; calibs, runs)`: both annotated `DataFrame`s, each carrying an `issues` column. Both come
back, not just the offending one — a dataset is accepted or rejected as a whole, and runs whose
calibration was rejected are not buildable anyway. They come back the same way whether or not
anything was wrong, so the return type never depends on the data; `isempty` on the `issues` column
is the question to ask.

Every row is validated, including rows `main`'s `run_ids` would have narrowed away: narrowing
decides what gets built, never what gets checked. There is correspondingly no `run_ids` here.

See also `only_track` and `only_rectify`, which serve the same debugging purpose by narrowing
instead.
"""
function verify(data_path::String; calibs_file = "calibs.csv", runs_file = "runs.csv",
        rectification_defaults = (;), tracking_defaults = (;))
    mkpath(RESULTS_DIR)
    calibs, runs = check_dataset(data_path, calibs_file, runs_file,
                                 rectification_defaults, tracking_defaults)
    return (; calibs, runs)
end

"""
    only_track(data_path; runs_file = "runs.csv", tracking_defaults = (;), run_ids = nothing)

Track the runs in `runs.csv` without any calibration, and return the tracks. A debugging entry
point: coordinates stay in image pixels because there is no rectification to carry them into
real-world units, and with no calibration there is no scene centre either — a first segment with no
`start_location` of its own falls back to the frame centre.

Each run's diagnostic video is written to `results_dir/<run_id>.mp4`, named by `run_id` exactly as
`main` names it (#68).
"""
function only_track(data_path::String; runs_file = "runs.csv", tracking_defaults = (;), run_ids = nothing)
    rs = gather_runs(data_path, runs_file, tracking_defaults, run_ids)
    # No calibration here, so no scene centre to fall back on and nothing to rectify through: a
    # first segment with no start_location of its own falls through to the frame centre.
    return @showprogress desc = "Building runs" tmap(
        r -> track(r, missing, nothing, joinpath(RESULTS_DIR, string(r.run_id, ".mp4"))), rs)
end

"""
    only_rectify(data_path; calibs_file = "calibs.csv", rectification_defaults = (;),
                 calibration_ids = nothing, rectification_diagnostics = false)

Build the rectifications described by `calibs.csv` and return them, without tracking anything. A
debugging entry point: it exercises the whole calibration path — reads, corner detection, the fit —
so a calibration can be checked before committing to a full run.

`calibration_ids` narrows which are built; `rectification_diagnostics` is as in `main`.
"""
function only_rectify(data_path::String; calibs_file = "calibs.csv", rectification_defaults = (;),
        calibration_ids = nothing, rectification_diagnostics::Bool = false)
    cs = gather_rectifications(data_path, calibs_file, rectification_defaults, calibration_ids)
    return build_rectifications(cs, rectification_diagnostics)
end
