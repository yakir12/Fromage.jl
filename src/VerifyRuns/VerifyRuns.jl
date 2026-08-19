module VerifyRuns

using DataFrames: AbstractDataFrame, DataFrame, allowmissing!, groupby, nrow
using ..Gateway: backfill!, blank!, read_per_file!, read_rows, report_issues, resolve_paths!,
    verify!
using ..Parsing: Parsing, MyTemporal, parseto!
import ..Parsing: mytryparse                # extended on MyWindow (a type this module owns)
using ..Probing: frame_geometry, no_video_stream, parse_framerate, parse_sar, probe_fields
using OhMyThreads: OhMyThreads, tmap
using ..PawsomeTracker: PawsomeTracker, ApriltagRectification, get_sigma
import ..PawsomeTracker: track
using PrecompileTools: @setup_workload, @compile_workload
using ProgressMeter: ProgressMeter, @showprogress
using Tables: Tables

export load_runs

# Every column maps onto a `PawsomeTracker.track` keyword, plus `run_id` (identity / segment grouping)
# and `path` (path resolution). This is the full set of recognized CSV columns; anything else is
# rejected as unrecognized.
const COLUMNS = (:calibration_id, :comment, :run_id, :path, :file, :start, :stop, :target_width, :start_location, :window_size, :darker_target, :fps, :initial_search_factor, :scale, :background_length)

include("types.jl")
include("parsers.jl")
include("verifications.jl")

function load_runs(file; strict = true, defaults = (;))
    load_runs(dirname(file), file; strict, defaults)
end

# `defaults` globally replaces the hardcoded fallbacks of the whitelisted tracking parameters
# (see DEFAULTS in parsers.jl); the hierarchy is csv cell → `defaults` → hardcoded/probed value.
function load_runs(data_path, file; strict = true, defaults = (;))
    defaults = resolve_defaults(defaults)   # fail fast on unknown keys / unconvertible values
    csvrows = read_rows(file, COLUMNS, "runs")

    # parse each row to a Dict of parsed values + an :issues accumulator
    cs = @showprogress desc = "Parsing runs.csv..." tmap(r -> parse_row(r, defaults), collect(csvrows))

    df = DataFrame(Tables.dictrowtable(cs))
    allowmissing!(df)

    # run_id is all-or-nothing (see resolve_run_ids!). Done before verification and grouping, so
    # :run_id is concrete on the clean path.
    resolve_run_ids!(df)

    verifications!(df, data_path)

    # a run_id that is missing (mixed numbering) or equal to the row number (auto-assigned) adds
    # nothing over "row $i", so it is only mentioned when the csv named the run itself
    if report_issues(df, :run_id, "runs.csv", "runs", strict;
                     mention = (i, rid) -> !ismissing(rid) && rid != string(i))
        return df
    end

    # Clean: group the rows by :run_id, each group materialized into one `Run`. `Run` is concrete,
    # so this vector's element type is too, and `track(r)` is statically dispatched.
    return Run[Run(g) for g in groupby(df, :run_id)]
end

include("precompile.jl")   # build-time workload; excluded from coverage

end
