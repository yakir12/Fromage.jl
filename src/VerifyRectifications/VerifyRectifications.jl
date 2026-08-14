module VerifyRectifications

using CSV: CSV
using ..Rectifications: get_corners, _vf, extrinsic_gray_frame
import ..Rectifications: Rectification
using ..PawsomeTracker: PawsomeTracker, ApriltagRectification
using FileIO: FileIO
using Chain: Chain, @chain
using DataFramesMeta: DataFramesMeta, @groupby, @rtransform!, @transform!, AbstractDataFrame,
    ByRow, Cols, DataFrame, Not, allowmissing!, completecases, dropmissing, groupby,
    nonunique, nrow, passmissing, select, select!, subset
using ..Parsing: Parsing, MyTemporal, parseto!
using ..Probing: probe_fields
using MAT: MAT, matread
using OhMyThreads: OhMyThreads, tmap
using PrecompileTools: @setup_workload, @compile_workload
using ProgressMeter: ProgressMeter, @showprogress
using Tables: Tables

export load_rectifications

const COLUMNS = (:comment, :calibration_id, :path, :file, :matlab_file, :start, :stop, :extrinsic, :checker_size, :center, :north, :n_corners, :scale, :type, :temporal_step, :radial_parameters, :blur, :extrinsic_index, :aspect, :yadif, :apriltags, :family)

include("types.jl")
include("parsers.jl")
include("verifications.jl")

# `issues_dir` is where the extrinsic frame of a calibration that fails checkerboard/AprilTag
# detection is dumped for inspection (see `verifications!`); it is emptied at the start of every run.
function load_rectifications(file; strict = true, defaults = (;), issues_dir = joinpath("results_dir", "issues"))
    data_path = dirname(file)
    load_rectifications(data_path, file; strict, defaults, issues_dir)
end

# `defaults` globally replaces the hardcoded fallbacks of the whitelisted rectification parameters
# (see DEFAULTS in parsers.jl); the hierarchy is csv cell → `defaults` → hardcoded/probed value.
function load_rectifications(data_path, file; strict = true, defaults = (;), issues_dir = joinpath("results_dir", "issues"))
    defaults = resolve_defaults(defaults)   # fail fast on unknown keys / unconvertible values
    # verify csv file exists
    if !isfile(file)
        error("calibration `.csv` file missing")
    end
    csvrows = CSV.Rows(file)

    # verify csv file has rows in it
    if isempty(Tables.rows(csvrows))
        error("csv file is empty")
    end

    # verify csv all the columns are expected
    sch = Tables.schema(csvrows)
    unrecognized = setdiff(sch.names, COLUMNS)
    if !isempty(unrecognized)
        error("unrecognized column/s in calibration file: $unrecognized")
    end

    # parse rows to RectificationMethods or error messages
    cs = @showprogress desc = "Parsing calibs.csv" tmap(r -> parse_row(r, defaults), collect(csvrows))

    df = DataFrame(Tables.dictrowtable(cs))
    allowmissing!(df)

    verifications!(df, data_path, issues_dir)

    if any(!isempty, df.issues)
        # a blank calibration_id cell is itself flagged as an issue, so it can be missing here
        msg = join([string(ismissing(cid) ? "row $i" : "row $i (calibration_id: $cid)", ": ", join(issues, ", "))
                    for (i, (cid, issues)) in enumerate(zip(df.calibration_id, df.issues)) if !isempty(issues)], '\n')
        println('\n' * "The following are issues with the calibs.csv file:\n" * msg)
        if strict
            error("there were issues with the calibration (see above)")
        else
            return df
        end
    end

    # The comprehension pins the element type to the abstract `Vector{RectificationMethod}`
    # (mirrors load_runs), so the clean-path return type doesn't vary with the mix of kinds.
    return RectificationMethod[RectificationMethod(r) for r in eachrow(df)]
end

include("precompile.jl")   # build-time workload; excluded from coverage

end
