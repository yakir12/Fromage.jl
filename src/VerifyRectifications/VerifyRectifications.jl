module VerifyRectifications

using ..ShareIO: ShareReadError
using ..Rectifications: get_corners, _vf, extrinsic_gray_frame, from_extrinsic, from_matlab,
    from_uniform, from_checkerboard
import ..Rectifications: Rectification
using ..PawsomeTracker: PawsomeTracker, ApriltagRectification
using FileIO: FileIO
using DataFrames: AbstractDataFrame, ByRow, DataFrame, Not, allowmissing!, completecases,
    dropmissing, groupby, nonunique, nrow, passmissing, subset
using ..Gateway: backfill!, blank!, read_per_file!, read_rows, report_issues, resolve_paths!,
    verify!, verify_id_filename!
using ..Parsing: Parsing, MyTemporal, filled, parseto!
using ..Paths: DEFAULT_ISSUES_DIR, run_issues_dir
using ..Probing: frame_geometry, is_interlaced, no_video_stream, parse_sample_aspect, probe_fields
using MAT: MAT, matread
using OhMyThreads: OhMyThreads, tmap
using PrecompileTools: @setup_workload, @compile_workload
using ProgressMeter: ProgressMeter, @showprogress
using Tables: Tables

export load_rectifications, check_rectifications

const COLUMNS = (:comment, :calibration_id, :path, :file, :matlab_file, :intrinsic_start, :intrinsic_stop, :extrinsic, :checker_width, :center, :north, :n_corners, :pixel_width, :type, :temporal_step, :radial_parameters, :blur, :extrinsic_index, :aspect, :yadif, :apriltags, :family, :tag_cell_width)

# Columns retired by a rename, and where each one's value went. Surfaced by `read_rows` when an
# old csv still names them — the file-level error fires before any row is parsed, so this is the
# only place such a user is reachable.
#
# The v0.2.23 three. `scale` is the one to be careful with: runs.csv has a `scale` column too, and
# it meant something else entirely (a downsampling factor, now `downscale`). The two gateways keep
# separate tables so a calibs.csv naming `scale` is never pointed at `downscale`, or the reverse.
# `start`/`stop` moved because runs.csv uses those names for the span of a run to TRACK, which is
# not this window — this one is when the checkerboard is being waved to fit the lens model.
const RENAMED_COLUMNS = Dict(
    :checker_size => "checker_width — or tag_cell_width on `type = apriltag` rows",
    :scale => "pixel_width (and `type = only_scale` is now `type = uniform`)",
    :start => "intrinsic_start",
    :stop => "intrinsic_stop",
)

include("types.jl")
include("parsers.jl")
include("verifications.jl")

# `issues_dir` is where the extrinsic frame of a calibration that fails checkerboard/AprilTag
# detection is dumped for inspection (see `verifications!`). Every run writes into a new time-stamped
# folder of its own inside it, so what a run dumped is exactly what its folder holds; nothing here is
# ever deleted, including anything the user keeps in the folder they name.
function load_rectifications(file; defaults = (;), issues_dir = DEFAULT_ISSUES_DIR, progress = true)
    load_rectifications(dirname(file), file; defaults, issues_dir, progress)
end

function check_rectifications(file; defaults = (;), issues_dir = DEFAULT_ISSUES_DIR, progress = true)
    check_rectifications(dirname(file), file; defaults, issues_dir, progress)
end

# `defaults` globally replaces the hardcoded fallbacks of the whitelisted rectification parameters
# (see DEFAULTS in parsers.jl); the hierarchy is csv cell → `defaults` → hardcoded/probed value.
# Read the csv and settle its identities: parse every cell, then the first tier of verification
# (`verify_ids!`), which touches nothing but `calibration_id`. Returns the annotated DataFrame —
# `:issues` carrying whatever the parse and that tier found — and whether every identity came
# through usable. Split out of `load_rectifications` so `main` can settle BOTH files' identities
# before either one opens a video (#121).
function parse_rectifications(data_path, file; defaults = (;), progress = true)
    defaults = resolve_defaults(defaults)   # fail fast on unknown keys / unconvertible values
    csvrows = read_rows(file, COLUMNS, "calibration"; renamed = RENAMED_COLUMNS)

    # parse rows to RectificationMethods or error messages
    cs = @showprogress desc = "Parsing calibs.csv" enabled = progress tmap(r -> parse_row(r, defaults), collect(csvrows))

    df = DataFrame(Tables.dictrowtable(cs))
    allowmissing!(df)

    # Counted rather than inferred from the messages: whatever `verify_ids!` adds, plus an identity
    # the parser could not read at all. `verify_unique_ids!` nulls the id of a repeat, so a
    # duplicate shows up in both halves.
    before = sum(length, df.issues)
    verify_ids!(df)
    identities_ok = sum(length, df.issues) == before && !any(ismissing, df.calibration_id)
    return df, identities_ok
end

# a blank calibration_id cell is itself flagged as an issue, so it can be missing here
report_calibs(df, strict) = report_issues(df, :calibration_id, "calibs.csv", "calibration", strict;
    mention = (i, cid) -> !ismissing(cid))

# The comprehension pins the element type to the abstract `Vector{RectificationMethod}` (as in
# load_runs), so the clean-path return type doesn't vary with the mix of kinds.
build_methods(df) = RectificationMethod[RectificationMethod(r) for r in eachrow(df)]

# Build the rectification methods, or throw. Always returns `Vector{RectificationMethod}`.
# The first-tier gate; see the matching comment in `load_runs`. This aborts before a single video is
# probed or corner-detected.
function load_rectifications(data_path, file; defaults = (;), issues_dir = DEFAULT_ISSUES_DIR,
        progress = true)
    df, identities_ok = parse_rectifications(data_path, file; defaults, progress)
    identities_ok || report_calibs(df, true)
    verifications!(df, data_path, issues_dir; progress)
    report_calibs(df, true)
    return build_methods(df)
end

# Validate and report, never throw. Always returns the annotated DataFrame — see `check_runs` for
# why that unconditional return is the point.
function check_rectifications(data_path, file; defaults = (;), issues_dir = DEFAULT_ISSUES_DIR,
        progress = true)
    df, identities_ok = parse_rectifications(data_path, file; defaults, progress)
    identities_ok || report_calibs(df, false)
    verifications!(df, data_path, issues_dir; progress)
    report_calibs(df, false)
    return df
end

include("precompile.jl")   # build-time workload; excluded from coverage

end
