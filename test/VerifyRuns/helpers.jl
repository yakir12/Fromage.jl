# Suite-specific helpers; the generic infrastructure (video/CSV builders, flagged, tracking
# ground truth, …) lives in test/common.jl, included by the wrapper module before this file.
using Test
using Fromage: VerifyRuns
using CSV, DataFrames

const VR = VerifyRuns

# ---------------------------------------------------------------------------
# Artifact generation (videos) into a shared directory.
# ---------------------------------------------------------------------------

# a.mp4 is the baseline run video (5 s, 640×480, 30 fps); b.mp4 is a second segment video (8 s);
# small.mp4 has different pixel dimensions (320×240) to exercise the dimension-consistency check.
const VIDEO_DURATION = 5

"Generate every shared artifact into `dir`; return a NamedTuple of their basenames."
function setup_artifacts(dir)
    make_video(joinpath(dir, "a.mp4"); duration = VIDEO_DURATION, size = (640, 480), rate = 30)
    make_video(joinpath(dir, "b.mp4"); duration = 8, size = (640, 480), rate = 30)
    make_video(joinpath(dir, "small.mp4"); duration = 5, size = (320, 240), rate = 30)
    make_corrupt_video(joinpath(dir, "corrupt.mp4"))
    return (a = "a.mp4", b = "b.mp4", small = "small.mp4", corrupt = "corrupt.mp4")
end

# the known-trajectory disc videos (test_tracking.jl) land in DATADIR like every other artifact
make_target_video(name; kw...) = make_target_video(DATADIR, name; kw...)

# ---------------------------------------------------------------------------
# CSV building. One canonical header; `row(; ...)` fills absent cells with missing.
# Only names from VerifyRuns.COLUMNS are allowed (others => "unrecognized column").
# ---------------------------------------------------------------------------

const HEADER = ["run_id", "calibration_id", "path", "file", "start", "stop", "target_width",
                "start_location", "window_size", "darker_target", "fps",
                "initial_search_factor", "white_point", "scale"]

row(; kw...) = buildrow(HEADER; kw...)
write_csv(path, rows; header = HEADER) = write_csv(path, rows, header)

# Clean baseline run row (run_id + calibration_id + a 5 s video; every other field defaults).
# Override any field via keyword to isolate one issue. Each scenario is loaded as its own CSV, so
# there is no cross-row coupling.
runrow(; kw...) = _merge((run_id = "r", calibration_id = "c", file = ART.a); kw...)

# ---------------------------------------------------------------------------
# Run + assert. DATADIR is defined in the wrapper module before any test file runs.
# ---------------------------------------------------------------------------

function check(name, rows; strict = false, header = HEADER, defaults = (;))
    csv = write_csv(joinpath(DATADIR, name), rows; header)
    VR.load_runs(DATADIR, csv; strict, defaults)
end

# A clean load returns Vector{Run}; a load with issues returns a DataFrame carrying :issues.
clean(x) = x isa Vector{VR.Run}
