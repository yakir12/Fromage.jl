# Every segment shares one resolution, codec and quality (see diagnose.jl), so a single ffmpeg
# concat-demuxer call stream-copies them into the final video, rewriting timestamps monotonically.
#
# Deliberately NOT routed through `ShareIO`: every path here is under `results_dir`, on local disk.
# The retries exist for the CIFS share and belong only on reads that cross it.
# ffmpeg takes each path in the list single-quoted, and a literal quote inside one is written
# `'\''` — close the string, escape the quote, reopen. An apostrophe is a legal file-name character
# and a plausible `run_id` ("beetle's run"); unescaped it closed the line early and took the segment
# with it. Everything else a file name may legally hold survives that quoting unchanged: backslashes
# and double quotes are literal inside it, spaces and control characters are preserved by it, and
# non-ASCII never mattered. That is asserted against real ffmpeg in the concat tests rather than
# reasoned about, the rule being ffmpeg's and not ours; absolute and drive-prefixed paths are what
# the `-safe 0` below allows, and ffmpeg rejects both without it.
#
# Two characters the quoting cannot rescue: the list holds one line per file, and ffmpeg ends a line
# at a newline or a carriage return whether or not it sits inside the quotes. Such a path splits into
# two entries, and what ffmpeg then says ("Line 2: unknown keyword") names neither the path nor the
# run it came from — so it is refused by name instead, and refused as soon as the path exists. That
# is the reason the gateway checks `run_id` rather than leaving it to fail at write time: the
# alternative is finding out after every run has already been tracked. The `run_id` half of each
# path is barred from every control character there (`id_filename_issue`), which leaves the temp
# root the segments sit under — checked in `main`, where that root is chosen.
function check_concat_representable(f)
    i = findfirst(c -> c == '\n' || c == '\r', f)
    isnothing(i) || throw(ArgumentError(
        "cannot write $(repr(f)) into ffmpeg's concat list: it contains $(repr(f[i])), and the \
         list holds one line per file — ffmpeg ends the line there whether or not it is quoted"))
    return nothing
end

concat_escape(f) = replace(f, "'" => raw"'\''")

function concatenate(path, files)
    foreach(check_concat_representable, files)   # all of them, before any of the list is written
    list = joinpath(path, "list.txt")
    open(list, "w") do io
        foreach(f -> println(io, "file '", concat_escape(f), "'"), files)
    end
    out = joinpath(RESULTS_DIR, "diagnostic.mp4")
    ffmpeg_exe(` -y -loglevel error -f concat -safe 0 -i $list -c copy $out`)
end

# Save one run's track to results_dir/<run_id>.csv: one row per coordinate, with the `time` stamp
# (seconds on the run's clock — the first segment's `start`, plus one sampling interval per tracked
# frame, so time left out between segments is closed up) and the `x`/`y` real-world coordinates.
# `track` returns coordinates the rectification's `image2real` has already been applied to, so the
# origin is at the rectification's `center`, north-aligned when `north` was given, in the
# rectification's real-world unit. Axis follows the image — x rightward, y downward — as
# `(y-direction, x-direction)`, hence the `y, x` unpack.
# That order is the `real` row of CONTEXT.md's table, which `Spaces` documents; this unpack is where
# the package's output contract meets it, and the only place the convention is undone.
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
# nothing. Filtering by id is a convenience for iterating on one run or rectification, so an id that
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
function gather_rectifications(data_path, rectifications_file, defaults, rectification_ids = nothing)
    mkpath(RESULTS_DIR)
    # `issues_dir` is left at its default, which Paths derives from `results_dir` — the frames a
    # failing rectification dumps land under the same output folder as everything else.
    cs = load_rectifications(joinpath(data_path, rectifications_file); defaults)
    return filter_ids!(cs, rectification_ids, :rectification_id, "rectification_ids")
end

function gather_runs(data_path, runs_file, defaults, run_ids = nothing)
    mkpath(RESULTS_DIR)
    rs = load_runs(joinpath(data_path, runs_file); defaults)
    return filter_ids!(rs, run_ids, :run_id, "run_ids")
end

# `rectification_diagnostics` stops here (#209). It is a caller instruction, and this is the caller:
# it used to travel five frames down into three otherwise-pure builders to reach a file write. What
# `save_diagnostic` needs is the rectification the builder just returned — `width`, `height`,
# `ratio` and `real2image` are all its fields — plus the three facts only the row carries: the
# source video, the extrinsic timestamp, and the id that names the image. An `apriltag`
# rectification has no fixed image->real map to warp through and quietly produces no image (that
# method is a no-op, in VerifyRectifications/types.jl); its top-down diagnostic is the per-run video
# instead.
function build_rectifications(cs, rectification_diagnostics::Bool)
    function build(c)
        rectification = Rectification(c)
        rectification_diagnostics &&
            save_diagnostic(rectification, c.source.file, c.source.extrinsic, c.rectification_id)
        return rectification
    end
    return @showprogress desc = "Building rectifications" tmap(build, cs)
end

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
function _validate_dataset(data_path, rectifications_file, runs_file, rectification_defaults, tracking_defaults)
    rects, rects_ids_ok = VerifyRectifications.parse_rectifications(
        data_path, joinpath(data_path, rectifications_file); defaults = rectification_defaults)
    runs, runs_ids_ok = VerifyRuns.parse_runs(
        data_path, joinpath(data_path, runs_file); defaults = tracking_defaults)

    # Coherence is a property of the two files AS WRITTEN, so it is checked on all of their rows —
    # before `run_ids` narrows anything. Narrowing decides what gets built, never what gets
    # validated; otherwise asking for one run would fail the rectifications it did not ask for.
    coherent = verify_cross_references!(rects, runs, :rectification_id, "rectifications.csv", "runs.csv")

    # The first-tier gate, across both files. Both are reported before the caller decides, so a user
    # fixing a dataset sees everything the csv text can tell them in one pass rather than one file's
    # problems per run.
    tier1_bad = false
    if !(rects_ids_ok && runs_ids_ok && coherent)
        tier1_bad = VerifyRectifications.report_rectifications(rects, false)
        tier1_bad |= VerifyRuns.report_runs(runs, false)
    end

    VerifyRectifications.verifications!(rects, data_path, DEFAULT_ISSUES_DIR)
    VerifyRuns.verifications!(runs, data_path)

    bad = VerifyRectifications.report_rectifications(rects, false)
    bad |= VerifyRuns.report_runs(runs, false)
    return rects, runs, (bad || tier1_bad)
end

# Build both, or throw. Always returns the two vectors.
function load_dataset(data_path, rectifications_file, runs_file, rectification_defaults, tracking_defaults)
    rects, runs, bad = _validate_dataset(data_path, rectifications_file, runs_file,
                                          rectification_defaults, tracking_defaults)
    bad && error("there were issues with the data (see above)")
    return VerifyRectifications.build_methods(rects), VerifyRuns.build_runs(runs)
end

# Validate and report, never throw. Always returns both annotated DataFrames — both, not just the
# offending one: a dataset is accepted or rejected as a whole, and runs whose rectification was
# rejected are not buildable anyway.
function check_dataset(data_path, rectifications_file, runs_file, rectification_defaults, tracking_defaults)
    rects, runs, _ = _validate_dataset(data_path, rectifications_file, runs_file,
                                        rectification_defaults, tracking_defaults)
    return rects, runs
end

"""
    main(data_path; rectifications_file = "rectifications.csv", runs_file = "runs.csv",
         rectification_defaults = (;), tracking_defaults = (;), run_ids = nothing,
         rectification_diagnostics = false)

Run the whole pipeline over the data folder `data_path`: validate `rectifications.csv` and `runs.csv` as one
dataset, build the map each rectification row describes, track every run through the one it names, and
write the results.

Returns a `DataFrame` with one row per run, carrying `run_id`, `rectification_id`, the built
`rectification`, and `track` — the track itself, as `(timestamps, coordinates)`.

Everything produced lands under `results_dir/`, created in the folder Julia was started in: one
`<run_id>.csv` per run (a row per coordinate, with `time` in seconds on the run's clock — starting
at its first segment's `start` — and `x`/`y` in the rectification's real-world unit, origin at its
`center`), and `diagnostic.mp4`.

# Keyword arguments

- `rectifications_file`, `runs_file`: the two csv file names, relative to `data_path`.

- `rectification_defaults`, `tracking_defaults`: globally replace the hardcoded defaults of the
  tracking and rectification parameters, e.g.
  `rectification_defaults = (n_corners = (5, 8), blur = 0)` or
  `tracking_defaults = (target_width = 60,)`. The hierarchy is: csv cell → these keywords → the
  hardcoded or probed default. Each gateway whitelists what may be set (see `DEFAULTS` in the
  respective `parsers.jl`) and rejects anything else up front.

- `run_ids`: restrict processing to the named runs. Only the rectifications those runs reference
  are built. An id matching no row is an error, not a request for less (#21).

- `rectification_diagnostics`: also save each rectification's extrinsic frame, warped through the
  rectification fitted to it, to `results_dir/rectifications/<rectification_id>.jpg`. The same "are
  the straight edges straight" check the diagnostic video offers, but available as soon as the
  rectifications are built rather than after every run has been tracked. An `apriltag` rectification
  has no fixed image→real map to warp through and quietly produces no image; its top-down
  diagnostic is the per-run video instead.

Issues in either csv abort the run. To inspect a dataset instead of processing it, call [`verify`](@ref),
which reports everything wrong with both files and returns them for inspection without building
anything.

See also `only_track` and `only_rectify`, the two narrowing entry points.
"""
function main(data_path::String; rectifications_file = "rectifications.csv", runs_file = "runs.csv",
        rectification_defaults = (;), tracking_defaults = (;), run_ids = nothing,
        rectification_diagnostics::Bool = false)
    mkpath(RESULTS_DIR)
    cs, rs = load_dataset(data_path, rectifications_file, runs_file, rectification_defaults, tracking_defaults)

    # Coherence guarantees every rectification is used, so with no `run_ids` this keeps all of them;
    # with one, it drops the rectifications the surviving runs no longer reference.
    rs = filter_ids!(rs, run_ids, :run_id, "run_ids")
    used_rectification_ids = [r.rectification_id for r in rs]
    filter!(c -> c.rectification_id ∈ used_rectification_ids, cs)

    rect_ids = [c.rectification_id for c in cs]
    rects = DataFrame(rectification_id = rect_ids, c = cs)

    rects.rectification .= build_rectifications(rects.c, rectification_diagnostics)

    runs = DataFrame(rectification_id = [r.rectification_id for r in rs], run_id = [r.run_id for r in rs], r = rs)
    leftjoin!(runs, rects, on = :rectification_id)

    mktempdir() do path
        transform!(runs, :run_id => (x -> joinpath.(path, string.(x, ".mp4"))) => :diagnostic_file)
        # Before anything is tracked: a segment path the concat list cannot hold would otherwise
        # surface only after every run had been built, which is the cost `concatenate` cannot undo.
        foreach(check_concat_representable, runs.diagnostic_file)
        build_run(r, c, rectification, diagnostic_file) =
            track(r, c.source.center, rectification, diagnostic_file)
        runs.track .= @showprogress desc = "Building runs" tmap(
            build_run, runs.r, runs.c, runs.rectification, runs.diagnostic_file)
        concatenate(path, runs.diagnostic_file)
        select!(runs, Not(:diagnostic_file))
    end

    tforeach(save2csv, runs.run_id, runs.track)

    return runs
end

# Each diagnostic is named by its run's `run_id`, as in `main` — which is the row number when the
# csv names no runs, and the run's own name when it does. Numbering by position instead would
# rename every file as soon as `run_ids` filtered one out.
"""
    verify(data_path; rectifications_file = "rectifications.csv", runs_file = "runs.csv",
           rectification_defaults = (;), tracking_defaults = (;))

Validate `rectifications.csv` and `runs.csv` in `data_path` as one dataset and report everything wrong with
them, **without building or tracking anything**. For looking at a dataset rather than processing it;
[`main`](@ref) is the one that does the work and aborts on any issue.

Returns `(; rectifications, runs)`: both annotated `DataFrame`s, each carrying an `issues` column. Both come
back, not just the offending one — a dataset is accepted or rejected as a whole, and runs whose
rectification was rejected are not buildable anyway. They come back the same way whether or not
anything was wrong, so the return type never depends on the data; `isempty` on the `issues` column
is the question to ask.

Every row is validated, including rows `main`'s `run_ids` would have narrowed away: narrowing
decides what gets built, never what gets checked. There is correspondingly no `run_ids` here.

See also `only_track` and `only_rectify`, which serve the same debugging purpose by narrowing
instead.
"""
function verify(data_path::String; rectifications_file = "rectifications.csv", runs_file = "runs.csv",
        rectification_defaults = (;), tracking_defaults = (;))
    mkpath(RESULTS_DIR)
    rects, runs = check_dataset(data_path, rectifications_file, runs_file,
                                rectification_defaults, tracking_defaults)
    return (; rectifications = rects, runs)
end

"""
    only_track(data_path; runs_file = "runs.csv", tracking_defaults = (;), run_ids = nothing)

Track the runs in `runs.csv` without any rectification, and return the tracks. A debugging entry
point: coordinates stay in image pixels because there is no rectification to carry them into
real-world units, and with no rectification there is no scene centre either — a first segment with no
`start_location` of its own falls back to the frame centre.

Each run's diagnostic video is written to `results_dir/<run_id>.mp4`, named by `run_id` exactly as
`main` names it (#68).
"""
function only_track(data_path::String; runs_file = "runs.csv", tracking_defaults = (;), run_ids = nothing)
    rs = gather_runs(data_path, runs_file, tracking_defaults, run_ids)
    # No rectification here, so no scene centre to fall back on and nothing to rectify through: a
    # first segment with no start_location of its own falls through to the frame centre.
    return @showprogress desc = "Building runs" tmap(
        r -> track(r, missing, nothing, joinpath(RESULTS_DIR, string(r.run_id, ".mp4"))), rs)
end

"""
    only_rectify(data_path; rectifications_file = "rectifications.csv", rectification_defaults = (;),
                 rectification_ids = nothing, rectification_diagnostics = false)

Build the rectifications described by `rectifications.csv` and return them, without tracking anything. A
debugging entry point: it exercises the whole rectification path — reads, corner detection, the fit —
so a rectification can be checked before committing to a full run.

`rectification_ids` narrows which are built; `rectification_diagnostics` is as in `main`.
"""
function only_rectify(data_path::String; rectifications_file = "rectifications.csv", rectification_defaults = (;),
        rectification_ids = nothing, rectification_diagnostics::Bool = false)
    cs = gather_rectifications(data_path, rectifications_file, rectification_defaults, rectification_ids)
    return build_rectifications(cs, rectification_diagnostics)
end
