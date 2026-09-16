# Every run diagnostic clip shares one resolution, codec and quality (see diagnose.jl), so a single ffmpeg
# concat-demuxer call stream-copies them into the final video, rewriting timestamps monotonically.
#
# Deliberately NOT routed through `ShareIO`: every path here is on local disk — the clips in the
# session's clip folder, the list beside them in a temp folder, the video under `results_dir`.
# The retries exist for the CIFS share and belong only on reads that cross it.
# ffmpeg takes each path in the list single-quoted, and a literal quote inside one is written
# `'\''` — close the string, escape the quote, reopen. An apostrophe is a legal file-name character
# and a plausible `run_id` ("beetle's run"); unescaped it closed the line early and took the clip
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
# folder the clips sit under — `Memo.CLIP_FOLDER`, checked in `main` before anything is tracked.
function check_concat_representable(f)
    i = findfirst(c -> c == '\n' || c == '\r', f)
    isnothing(i) || throw(
        ArgumentError(
            "cannot write $(repr(f)) into ffmpeg's concat list: it contains $(repr(f[i])), and the \
         list holds one line per file — ffmpeg ends the line there whether or not it is quoted"
        )
    )
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
    return ffmpeg_exe(` -y -loglevel error -f concat -safe 0 -i $list -c copy $out`)
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
    return open(joinpath(RESULTS_DIR, string(run_id, ".csv")), "w") do io
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
# nothing. Filtering by id is a convenience for iterating on one run, so an id that matches nothing
# is a typo rather than a request for less: every requested id must match (#21).
function filter_ids!(xs, requested, id, what)
    isnothing(requested) && return xs
    available = [getfield(x, id) for x in xs]
    unmatched = setdiff(requested, available)
    if !isempty(unmatched)
        error("unknown $id(s) in `$(what)`: $(sort(unmatched)). Available $(id)s: $(sort(available))")
    end
    return filter!(x -> getfield(x, id) ∈ requested, xs)
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
        rectification = build_rectification(c)
        rectification_diagnostics &&
            save_diagnostic(rectification, c.source.file, c.source.extrinsic, c.rectification_id)
        return rectification
    end
    return @showprogress desc = "Building rectifications" tmap(build, cs)
end

# Memoized on its whole argument list, which is `c` and nothing else — the rule every memo in this
# package follows (see `Memo`, which also owns the "a cached build is never revalidated against the
# file it was built from" contract this inherits). A user who edited a `runs.csv` row changed no
# rectification, and a second `main` in the same session rebuilds none of them (#251).
#
# `save_diagnostic` is deliberately OUTSIDE this, in `build_rectifications` above: the image is the
# caller's (#209), so every invocation renders its own even when the rectification it renders was
# served from the cache — the same split the issue-frame dump keeps on the verification side (#86,
# #210). A build that throws stores nothing, so a share hiccup is retried rather than remembered.
#
# `c` is annotated, which the caches below `Memo` cannot do (they are declared above the modules that
# own their key types) and this can: `main.jl` is included last, so the type exists here. It is worth
# the line because the cache is an `LRU{Any, Any}` — without it a `DataFrameRow`, which `Memo`'s
# header warns hashes by OBJECT IDENTITY, would be accepted and memoized on a key that never hits
# twice, instead of raising a `MethodError` at the call site that passed the wrong thing.
build_rectification(c::VerifyRectifications.RectificationMethod) =
    get!(() -> Rectification(c), BUILT_RECTIFICATIONS, c)

# The key `TRACKED_RUNS` files a track under: every field of the run, as a tuple, plus the
# rectification method. Spelled from `fieldcount` rather than field by field, so a field added to
# `Run` joins the key without this line being touched — and test/memo.jl varies each one on its own
# to say so. Why not `r` itself is in `Memo`, beside the cache.
tracking_key(r::VerifyRuns.Run, c::VerifyRectifications.RectificationMethod) =
    (ntuple(i -> getfield(r, i), fieldcount(VerifyRuns.Run))..., c)

# Track one run through the rectification `c` describes, memoized for the session (#249). Returns the
# track, the path of its run diagnostic clip, and whether both were served from the cache.
#
# The key is the whole argument list, `r` and `c` (see `tracking_key`), which is why this takes the
# method rather than the built rectification: the rectification and the fallback centre are both
# functions of `c`, and `build_rectification` hands the rectification back from its own cache — `main`
# has always built it by then. Fetched only on a miss, so a cached track touches no other cache.
#
# The clip is written into a folder of the cache's own, named `<run_id>.mp4` because a clip's label is
# its file name (#22). A track that throws is stored by nothing (`get!`), its clip is already deleted
# (#160), and the folder goes too, so a failed run leaves no trace to be mistaken for a finished one.
function track_run(r::VerifyRuns.Run, c::VerifyRectifications.RectificationMethod)
    missed = Ref(false)
    track_, clip = get!(TRACKED_RUNS, tracking_key(r, c)) do
        missed[] = true
        folder = mktempdir(CLIP_FOLDER(); cleanup = false)
        file = joinpath(folder, string(r.run_id, ".mp4"))
        tracked = false
        try
            value = (track(r, c.source.center, build_rectification(c), file), file)
            tracked = true
            return value
        finally
            tracked || rm(folder; recursive = true, force = true)
        end
    end
    return track_, clip, !missed[]
end

# Every run, in parallel. Run ids are unique within a dataset, so no two of these share a key and no
# two tasks ever compute the same entry.
track_runs(rs, cs) = @showprogress desc = "Building runs" tmap(track_run, rs, cs)

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
        data_path, joinpath(data_path, rectifications_file); defaults = rectification_defaults
    )
    runs, runs_ids_ok = VerifyRuns.parse_runs(
        data_path, joinpath(data_path, runs_file); defaults = tracking_defaults
    )

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
    rects, runs, bad = _validate_dataset(
        data_path, rectifications_file, runs_file,
        rectification_defaults, tracking_defaults
    )
    bad && error("there were issues with the data (see above)")
    return VerifyRectifications.build_methods(rects), VerifyRuns.build_runs(runs)
end

# Validate and report, never throw. Always returns both annotated DataFrames — both, not just the
# offending one: a dataset is accepted or rejected as a whole, and runs whose rectification was
# rejected are not buildable anyway.
function check_dataset(data_path, rectifications_file, runs_file, rectification_defaults, tracking_defaults)
    rects, runs, _ = _validate_dataset(
        data_path, rectifications_file, runs_file,
        rectification_defaults, tracking_defaults
    )
    return rects, runs
end

"""
    main(data_path; rectifications_file = "rectifications.csv", runs_file = "runs.csv",
         rectification_defaults = (;), tracking_defaults = (;), run_ids = nothing,
         rectification_diagnostics = false)

Run the whole pipeline over the data folder `data_path`: validate `rectifications.csv` and `runs.csv` as one
dataset, build the map each rectification row describes, track every run through the one it names, and
write the results. Returns `nothing`.

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
  rectifications are built rather than after every run has been tracked: every rectification is built,
  and its image saved, before the first run is tracked, so a wrong one can be spotted and `main`
  interrupted without waiting for the tracking. An `apriltag` rectification
  has no fixed image→real map to warp through and quietly produces no image; its top-down
  diagnostic is the per-run video instead.

Issues in either csv abort the run. To inspect a dataset instead of processing it, call [`verify`](@ref),
which reports everything wrong with both files and returns them for inspection without building
anything.
"""
function main(
        data_path::String; rectifications_file = "rectifications.csv", runs_file = "runs.csv",
        rectification_defaults = (;), tracking_defaults = (;), run_ids = nothing,
        rectification_diagnostics::Bool = false
    )
    mkpath(RESULTS_DIR)
    cs, rs = load_dataset(data_path, rectifications_file, runs_file, rectification_defaults, tracking_defaults)

    # Coherence guarantees every rectification is used, so with no `run_ids` this keeps all of them;
    # with one, it drops the rectifications the surviving runs no longer reference.
    rs = filter_ids!(rs, run_ids, :run_id, "run_ids")
    used_rectification_ids = [r.rectification_id for r in rs]
    filter!(c -> c.rectification_id ∈ used_rectification_ids, cs)

    # Every rectification is built, and its `rectification_diagnostics` image written, BEFORE any run
    # is tracked — `build_rectifications` returns only once all of them are done, and the tracking
    # below starts after it. docs/src/help.md relies on that order: it tells a user to watch
    # `results_dir/rectifications/` fill and interrupt `main` if an image is wrong, which is only
    # cheap while nothing has been tracked yet (#256). What it returns is not kept: `track_run` takes
    # each back out of the build cache.
    build_rectifications(cs, rectification_diagnostics)

    # Before anything is tracked: a clip path the concat list cannot hold would otherwise surface only
    # after every run had been tracked, which is the cost `concatenate` cannot undo. `run_id`, the
    # other half of every clip path, the gateway has already checked.
    check_concat_representable(CLIP_FOLDER())

    method = Dict(c.rectification_id => c for c in cs)
    tracked = track_runs(rs, [method[r.rectification_id] for r in rs])

    # Said only when something was reused, because a cached track inherits the memo's caveat: a video
    # replaced in place serves the track of the file it replaced.
    reused = count(t -> t[3], tracked)
    reused > 0 && @info "Reused $reused of $(length(tracked)) tracks from earlier in this session; \
        Fromage.empty_caches!() forces a re-track"

    # Every invocation writes everything, hit or miss: the csvs, and the diagnostic video stitched
    # from every run's clip in run order. Only the tracking was skipped.
    mktempdir(path -> concatenate(path, [clip for (_, clip, _) in tracked]))
    tforeach((r, (track_, _, _)) -> save2csv(r.run_id, track_), rs, tracked)

    return nothing
end

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
"""
function verify(
        data_path::String; rectifications_file = "rectifications.csv", runs_file = "runs.csv",
        rectification_defaults = (;), tracking_defaults = (;)
    )
    mkpath(RESULTS_DIR)
    rects, runs = check_dataset(
        data_path, rectifications_file, runs_file,
        rectification_defaults, tracking_defaults
    )
    return (; rectifications = rects, runs)
end

"""
    Fromage.empty_caches!()

Forget every memoized read, detection, built rectification and track, so the next call to
[`main`](@ref) or [`verify`](@ref) re-probes, re-reads, re-detects, rebuilds and re-tracks everything
from disk. The run diagnostic clips kept with the tracks are deleted from disk with them.

A Julia session remembers what it read — one ffprobe per video, one `matread` per calibration file,
one detection per rectification — what it BUILT: one built rectification per `rectifications.csv`
row (#233, #251) — and what it TRACKED: one track per run, with its run diagnostic clip (#249). So
re-running `main` after fixing a csv row re-does only what that row changed, and `main` logs how many
tracks it reused. Those memos are keyed on file PATHS, and a built rectification or a track on the
specification naming one, and
neither is ever revalidated against the files themselves — so this is what to call after changing the
contents of a video or `.mat` file **in place**, without changing its name — and after redefining
one of Fromage's own functions under `Revise.jl`. Starting a fresh Julia session does the same
thing.

The caches are in `Fromage.Memo`, whose header states what each one holds and how it is keyed.
"""
empty_caches!() = (foreach(empty!, Memo.CACHES); nothing)
