using Test
using Fromage: VerifyRuns
using CSV, DataFrames
using FFMPEG
using Statistics: mean

const VR = VerifyRuns

# ---------------------------------------------------------------------------
# Artifact generation (videos) into a shared directory.
# ---------------------------------------------------------------------------

function make_video(path; duration = 5, size = (640, 480), rate = 30)
    w, h = size
    FFMPEG.ffmpeg_exe(`-y -loglevel error -f lavfi -i testsrc=duration=$duration:size=$(w)x$(h):rate=$rate -pix_fmt yuv420p $path`)
    path
end

make_corrupt_video(path) = (write(path, rand(UInt8, 500)); path)

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

# ---------------------------------------------------------------------------
# CSV building. One canonical header; `row(; ...)` fills absent cells with missing.
# Only names from VerifyRuns.COLUMNS are allowed (others => "unrecognized column").
# ---------------------------------------------------------------------------

const HEADER = ["run_id", "calibration_id", "path", "file", "start", "stop", "target_width",
                "start_location", "window_size", "darker_target", "fps", "apriltags",
                "initial_search_factor", "white_point", "scale"]

# A kwarg not in HEADER would otherwise be dropped silently, quietly testing nothing.
function row(; kw...)
    unknown = setdiff(string.(keys(kw)), HEADER)
    @assert isempty(unknown) "unknown CSV column/s in test row: $unknown"
    return [get(kw, Symbol(c), missing) for c in HEADER]
end

# Clean baseline run row (run_id + calibration_id + a 5 s video; every other field defaults).
# Override any field via keyword to isolate one issue. Each scenario is loaded as its own CSV, so
# there is no cross-row coupling.
_merge(base; kw...) = row(; merge(base, values(kw))...)
runrow(; kw...) = _merge((run_id = "r", calibration_id = "c", file = ART.a); kw...)

csvcell(::Missing) = ""
function csvcell(x)
    s = x isa AbstractString ? String(x) : string(x)
    (occursin(',', s) || occursin('"', s)) ? string('"', replace(s, '"' => "\"\""), '"') : s
end

function write_csv(path, rows; header = HEADER)
    open(path, "w") do io
        println(io, join(header, ","))
        for r in rows
            println(io, join(csvcell.(r), ","))
        end
    end
    path
end

# ---------------------------------------------------------------------------
# Run + assert. DATADIR is defined in runtests.jl before any test file runs.
# A clean load returns Vector{Run}; a load with issues returns the DataFrame (non-strict).
# ---------------------------------------------------------------------------

function check(name, rows; strict = false, header = HEADER)
    csv = write_csv(joinpath(DATADIR, name), rows; header)
    VR.load_runs(DATADIR, csv; strict)
end

"Like `check`, but also capture stdout. Returns (result, output). Routed through a temp file because
redirect_stdout needs a real file descriptor, not an IOBuffer."
function load_capturing(name, rows; strict = false)
    mktemp() do path, io
        result = redirect_stdout(() -> check(name, rows; strict), io)
        flush(io)
        result, read(path, String)
    end
end

# A clean load returns Vector{Run}; a load with issues returns a DataFrame carrying :issues.
flagged(x, r, sub) = x isa AbstractDataFrame && any(m -> occursin(sub, m), x.issues[r])
clean(x) = x isa Vector{VR.Run}

# ---------------------------------------------------------------------------
# Synthetic tracking videos with a known trajectory (test_tracking.jl).
# ---------------------------------------------------------------------------

# A disc whose display-space center follows x(N) = col − A·sin(0.5π·N/fps), y(N) = row (ffmpeg
# 0-based coordinates, A = width/2.5), drawn by ffmpeg's geq expression at width×height square
# pixels, then squeezed to (width/sar)×height stored pixels with setsar=sar — a genuinely
# anamorphic file when sar ≠ 1. `nsegments > 1` splits the same trajectory into several files on
# forced keyframes (a segmented run). Returns the basename(s) and the ground-truth closure
# `expected(i; skip, offset)`: the stored-frame 1-based (row, col) of the disc center at sample i,
# where sample i reads global frame `offset + (i − 1)·skip` (skip = video fps ÷ requested fps).
function make_target_video(name; width = 100, height = 100, sar = 1//1, fps = 25, duration = 2,
        target_width = 10, darker_target = true, row = 50, col = 55, nsegments = 1)
    A = width / 2.5
    target_c, bkgd_c = darker_target ? (0, 255) : (255, 0)
    w2 = round(Int, width / sar)
    sarg = "$(numerator(sar))/$(denominator(sar))"
    vf = "geq=lum='if(lt(sqrt((X-$col+$A*sin(0.5*PI*N/$fps))^2+(Y-$row)^2),$(target_width/2)),$target_c,$bkgd_c)':cb=128:cr=128,scale=$w2:$height,setsar=$sarg"
    # -qp 0: lossless — the analytic ground truth stays exact, with no encoder noise around the disc
    src = `-y -loglevel error -f lavfi -i color=white:s=$(width)x$(height):d=$duration:r=$fps -vf $vf -pix_fmt yuv420p -qp 0`
    files = if nsegments == 1
        FFMPEG.ffmpeg_exe(`$src $(joinpath(DATADIR, "$name.mp4"))`)
        ["$name.mp4"]
    else
        T = duration / nsegments
        kf = "expr:gte(t,n_forced*$T)"
        FFMPEG.ffmpeg_exe(`$src -force_key_frames $kf -f segment -segment_time $T $(joinpath(DATADIR, name * "_%02d.mp4"))`)
        [string(name, "_", lpad(k, 2, '0'), ".mp4") for k in 0:(nsegments - 1)]
    end
    expected = (i; skip = 1, offset = 0) -> begin
        N = offset + (i - 1) * skip
        (row + 1.0, (col - A * sin(0.5π * N / fps)) / sar + 1)
    end
    return files, expected
end

"RMSE (in stored-frame pixels) between tracked coordinates and the ground-truth closure."
function tracking_rmse(ij, expected; skip = 1, offset = 0)
    sqrt(mean([sum(abs2, Tuple(rc) .- expected(i; skip, offset)) for (i, rc) in enumerate(ij)]))
end
