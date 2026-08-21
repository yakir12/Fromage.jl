# Everything specific to this gateway: the artifacts, the column header, and the four entry points
# its test files use. The generic infrastructure lives in test/fixtures.jl (synthetic videos,
# ffprobe readers) and test/harness.jl (CSV building, `flagged`, `capturing`).
using Test
using Fromage: VerifyRuns
using CSV, DataFrames
import ..Fixtures: make_target_video
import ..Harness

const VR = VerifyRuns

# ---------------------------------------------------------------------------
# Artifact generation (videos) into DATADIR.
# ---------------------------------------------------------------------------

const VIDEO_DURATION = 5

# a.mp4 is the baseline run video (5 s, 640×480, 30 fps); b.mp4 is a second segment video (8 s);
# small.mp4 has different pixel dimensions (320×240) to exercise the dimension-consistency check.
const ART = let dir = DATADIR
    make_video(joinpath(dir, "a.mp4"); duration = VIDEO_DURATION, size = (640, 480), rate = 30)
    make_video(joinpath(dir, "b.mp4"); duration = 8, size = (640, 480), rate = 30)
    make_video(joinpath(dir, "small.mp4"); duration = 5, size = (320, 240), rate = 30)
    make_corrupt_video(joinpath(dir, "corrupt.mp4"))
    (a = "a.mp4", b = "b.mp4", small = "small.mp4", corrupt = "corrupt.mp4")
end

# the known-trajectory disc videos (test_tracking.jl) land in DATADIR like every other artifact
make_target_video(name; kw...) = make_target_video(DATADIR, name; kw...)

# ---------------------------------------------------------------------------
# CSV building. One canonical header; `row(; ...)` fills absent cells with missing.
# Only names from VerifyRuns.COLUMNS are allowed (others => "unrecognized column").
# ---------------------------------------------------------------------------

const HEADER = ["run_id", "calibration_id", "path", "file", "start", "stop", "target_width",
                "start_location", "window_size", "darker_target", "fps",
                "initial_search_factor", "scale", "background_length"]

row(; kw...) = buildrow(HEADER; kw...)
# Module-local, and deliberately not a method on `Harness.write_csv`: both suites would add
# the same two-argument signature to it, and the second would silently replace the first (#115).
write_rows(path, rows; header = HEADER) = Harness.write_csv(path, rows, header)
_merge(base; kw...) = row(; merge(base, values(kw))...)

# Clean baseline run row (run_id + calibration_id + a 5 s video; every other field defaults).
# Override any field via keyword to isolate one issue. Each scenario is loaded as its own CSV, so
# there is no cross-row coupling.
runrow(; kw...) = _merge((run_id = "r", calibration_id = "c", file = ART.a); kw...)

# ---------------------------------------------------------------------------
# Run + assert.
# ---------------------------------------------------------------------------

function check(name, rows; strict = false, header = HEADER, defaults = (;))
    csv = write_rows(joinpath(DATADIR, name), rows; header)
    VR.load_runs(DATADIR, csv; strict, defaults)
end

# Each scenario is loaded as its own csv, so the name only has to be unique within DATADIR — the
# suite generates it. Name one explicitly only when the test is about the file itself.
const CASE = Ref(0)
check(rows; kw...) = check("case_$(CASE[] += 1).csv", rows; kw...)

"Like `check`, but also capture what the load prints to stdout. Returns (result, output)."
load_capturing(name, rows; kw...) = capturing(() -> check(name, rows; kw...))
load_capturing(rows; kw...) = capturing(() -> check(rows; kw...))

# A clean load returns Vector{Run}; a load with issues returns a DataFrame carrying :issues.
clean(x) = x isa Vector{VR.Run}
