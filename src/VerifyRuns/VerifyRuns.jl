module VerifyRuns

using CSV: CSV
using Chain: Chain, @chain
using DataFramesMeta: DataFramesMeta, @transform!, AbstractDataFrame, ByRow, Cols,
    DataFrame, Not, allowmissing!, dropmissing, groupby, nrow, passmissing, select!, subset
using ..Parsing: Parsing, MyTemporal, parseto!
import ..Parsing: mytryparse                # extended on MyWindow (a type this module owns)
using ..Probing: probe_fields
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
    # verify csv file exists
    if !isfile(file)
        error("runs `.csv` file missing")
    end
    csvrows = CSV.Rows(file)

    # verify csv file has rows in it
    if isempty(Tables.rows(csvrows))
        error("csv file is empty")
    end

    # verify all the columns are expected
    sch = Tables.schema(csvrows)
    unrecognized = setdiff(sch.names, COLUMNS)
    if !isempty(unrecognized)
        error("unrecognized column/s in runs file: $unrecognized")
    end

    # parse each row to a Dict of parsed values + an :issues accumulator
    cs = @showprogress desc = "Parsing runs.csv..." tmap(r -> parse_row(r, defaults), collect(csvrows))

    df = DataFrame(Tables.dictrowtable(cs))
    allowmissing!(df)

    # run_id is all-or-nothing (see resolve_run_ids!). Done before verification and grouping, so
    # :run_id is concrete on the clean path.
    resolve_run_ids!(df)

    verifications!(df, data_path)

    if any(!isempty, df.issues)
        # a run_id that is missing (mixed numbering) or equal to the row number (auto-assigned)
        # adds nothing over "row $i", so it is only mentioned when the csv named the run itself
        msg = join([string(ismissing(rid) || rid == string(i) ? "row $i" : "row $i (run_id: $rid)", ": ", join(issues, ", "))
                    for (i, (rid, issues)) in enumerate(zip(df.run_id, df.issues)) if !isempty(issues)], '\n')
        println('\n' * "The following are issues with the runs.csv file:\n" * msg)
        if strict
            error("there were issues with the runs (see above)")
        else
            return df
        end
    end

    # Clean: group the rows by :run_id, each group materialized into its concrete run type
    # (SingleRun / MultiRun). The comprehension pins the element type to the abstract `Vector{Run}`.
    return Run[Run(g) for g in groupby(df, :run_id)]
end

include("precompile.jl")   # build-time workload; excluded from coverage

end
