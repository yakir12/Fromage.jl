module VerifyRectifications

using ..ShareIO: ShareReadError
using ..Rectifications: get_corners, _vf, extrinsic_gray_frame, from_extrinsic, from_matlab,
    from_scale, from_video
import ..Rectifications: Rectification
using ..PawsomeTracker: PawsomeTracker, ApriltagRectification
using FileIO: FileIO
using DataFrames: AbstractDataFrame, ByRow, DataFrame, Not, allowmissing!, completecases,
    dropmissing, groupby, nonunique, nrow, passmissing, subset
using ..Gateway: backfill!, blank!, read_per_file!, read_rows, report_issues, resolve_paths!,
    verify!
using ..Parsing: Parsing, MyTemporal, parseto!
using ..Paths: DEFAULT_ISSUES_DIR, run_issues_dir
using ..Probing: frame_geometry, is_interlaced, no_video_stream, parse_sample_aspect, probe_fields
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
# detection is dumped for inspection (see `verifications!`). Every run writes into a new time-stamped
# folder of its own inside it, so what a run dumped is exactly what its folder holds; nothing here is
# ever deleted, including anything the user keeps in the folder they name.
function load_rectifications(file; strict = true, defaults = (;), issues_dir = DEFAULT_ISSUES_DIR)
    data_path = dirname(file)
    load_rectifications(data_path, file; strict, defaults, issues_dir)
end

# `defaults` globally replaces the hardcoded fallbacks of the whitelisted rectification parameters
# (see DEFAULTS in parsers.jl); the hierarchy is csv cell → `defaults` → hardcoded/probed value.
function load_rectifications(data_path, file; strict = true, defaults = (;), issues_dir = DEFAULT_ISSUES_DIR)
    defaults = resolve_defaults(defaults)   # fail fast on unknown keys / unconvertible values
    csvrows = read_rows(file, COLUMNS, "calibration")

    # parse rows to RectificationMethods or error messages
    cs = @showprogress desc = "Parsing calibs.csv" tmap(r -> parse_row(r, defaults), collect(csvrows))

    df = DataFrame(Tables.dictrowtable(cs))
    allowmissing!(df)

    verifications!(df, data_path, issues_dir)

    # a blank calibration_id cell is itself flagged as an issue, so it can be missing here
    if report_issues(df, :calibration_id, "calibs.csv", "calibration", strict;
                     mention = (i, cid) -> !ismissing(cid))
        return df
    end

    # The comprehension pins the element type to the abstract `Vector{RectificationMethod}` (as in
    # load_runs), so the clean-path return type doesn't vary with the mix of kinds.
    return RectificationMethod[RectificationMethod(r) for r in eachrow(df)]
end

include("precompile.jl")   # build-time workload; excluded from coverage

end
