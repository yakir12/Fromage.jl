module VerifyRuns

using DataFrames: AbstractDataFrame, DataFrame, allowmissing!, groupby, nrow
using ..Gateway: backfill!, blank!, read_per_file!, read_rows, report_issues, resolve_paths!,
    verify!, verify_id_filename!
using ..Parsing: Parsing, MyTemporal, parseto!
import ..Parsing: mytryparse                # extended on MyWindow (a type this module owns)
using ..Probing: frame_geometry, no_video_stream, parse_framerate, parse_sar, probe_fields
using OhMyThreads: OhMyThreads, tmap
using ..PawsomeTracker: PawsomeTracker, ApriltagRectification, Segment, Tuning, get_window
import ..PawsomeTracker: track
using PrecompileTools: @setup_workload, @compile_workload
using ProgressMeter: ProgressMeter, @showprogress
using Tables: Tables

export load_runs

# Every column maps onto a field of `PawsomeTracker.Segment` or `PawsomeTracker.Tuning`, plus
# `run_id` (identity / segment grouping) and `path` (path resolution). This is the full set of
# recognized CSV columns; anything else is rejected as unrecognized.
const COLUMNS = (:calibration_id, :comment, :run_id, :path, :file, :start, :stop, :target_width, :start_location, :window_size, :darker_target, :native_fps, :sample_fps, :initial_search_factor, :scale, :background_length)

# `fps` meant two different rates at once — the video's own and the one to sample it at — which is
# why it is gone rather than kept as a synonym for either. A file that still has the column is
# rejected with the hint below, since neither reading of it can be assumed (see runs.md).
const RENAMED_COLUMNS = Dict(
    :fps => "sample_fps — the video's own rate is native_fps",
)

include("types.jl")
include("parsers.jl")
include("verifications.jl")

function load_runs(file; strict = true, defaults = (;), progress = true)
    load_runs(dirname(file), file; strict, defaults, progress)
end

# Read the csv and settle its identities: parse every cell, then the first tier of verification
# (`verify_ids!`), which touches nothing but `run_id` and `calibration_id`. Returns the annotated
# DataFrame — `:issues` carrying whatever the parse and that tier found — and whether every identity
# came through usable. Split out of `load_runs` so `main` can settle BOTH files' identities before
# either one opens a video (#121).
function parse_runs(data_path, file; defaults = (;), progress = true)
    defaults = resolve_defaults(defaults)   # fail fast on unknown keys / unconvertible values
    csvrows = read_rows(file, COLUMNS, "runs"; renamed = RENAMED_COLUMNS)

    # parse each row to a Dict of parsed values + an :issues accumulator
    cs = @showprogress desc = "Parsing runs.csv..." enabled = progress tmap(r -> parse_row(r, defaults), collect(csvrows))

    df = DataFrame(Tables.dictrowtable(cs))
    allowmissing!(df)

    # Identity failures are what the gate in `load_runs` (and, for the cross-file check, `main`)
    # keys on, so they are counted rather than inferred from the messages: whatever `verify_ids!`
    # adds, plus an identity the parser could not read at all.
    before = sum(length, df.issues)
    verify_ids!(df)
    identities_ok = sum(length, df.issues) == before &&
        !any(ismissing, df.run_id) && !any(ismissing, df.calibration_id)
    return df, identities_ok
end

# a run_id that is missing (mixed numbering) or equal to the row number (auto-assigned) adds
# nothing over "row $i", so it is only mentioned when the csv named the run itself
report_runs(df, strict) = report_issues(df, :run_id, "runs.csv", "runs", strict;
    mention = (i, rid) -> !ismissing(rid) && rid != string(i))

# Clean: group the rows by :run_id, each group materialized into one `Run`. `Run` is concrete, so
# this vector's element type is too, and `track(r)` is statically dispatched.
build_runs(df) = Run[Run(g) for g in groupby(df, :run_id)]

# `defaults` globally replaces the hardcoded fallbacks of the whitelisted tracking parameters
# (see DEFAULTS in parsers.jl); the hierarchy is csv cell → `defaults` → hardcoded/probed value.
function load_runs(data_path, file; strict = true, defaults = (;), progress = true)
    df, identities_ok = parse_runs(data_path, file; defaults, progress)

    # The first-tier gate. Under `strict` the run is going to abort whatever the videos say, so it
    # aborts here rather than spending minutes of reads on a report that would be discarded. Without
    # it the rows stay and are quarantined instead: every second-tier stage skips flagged rows, so
    # the rest of the file is still validated and the caller gets one combined report at the end.
    #
    # Only identity issues open this gate. A malformed `start` in one row does not make the other
    # rows' videos less worth checking, so it rides along to the full report rather than cutting the
    # run short.
    identities_ok || (strict && report_runs(df, true))

    verifications!(df, data_path; progress)

    report_runs(df, strict) && return df
    return build_runs(df)
end

include("precompile.jl")   # build-time workload; excluded from coverage

end
