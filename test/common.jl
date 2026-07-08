# Test infrastructure shared by the suites, `include`d into each suite's wrapper module — the
# things that genuinely differ per suite (DATADIR, HEADER, the baseline rows, `check`, `clean`)
# stay module-local, while these definitions are written once. Functions that reference a
# module-local name (`row` in `_merge`, `check` in `load_capturing`, `write_csv`'s per-suite
# HEADER default) resolve it in the including module at call time.

using DataFrames: AbstractDataFrame
using FFMPEG: FFMPEG
using Statistics: mean

# ---------------------------------------------------------------------------
# Video artifacts.
# ---------------------------------------------------------------------------

function make_video(path; duration = 5, size = (640, 480), rate = 30)
    w, h = size
    FFMPEG.ffmpeg_exe(`-y -loglevel error -f lavfi -i testsrc=duration=$duration:size=$(w)x$(h):rate=$rate -pix_fmt yuv420p $path`)
    path
end

function make_checkerboard_video(path, png; duration = 5)
    pad = "pad=ceil(iw/2)*2:ceil(ih/2)*2"   # libx264/yuv420p needs even dimensions
    FFMPEG.ffmpeg_exe(`-y -loglevel error -framerate 10 -loop 1 -i $png -t $duration -vf $pad -pix_fmt yuv420p $path`)
    path
end

make_corrupt_video(path) = (write(path, rand(UInt8, 500)); path)

# A disc whose display-space center follows x(N) = col − A·sin(0.5π·N/fps), y(N) = row (ffmpeg
# 0-based coordinates, A = width/2.5), drawn by ffmpeg's geq expression at width×height square
# pixels, then squeezed to (width/sar)×height stored pixels with setsar=sar — a genuinely
# anamorphic file when sar ≠ 1. `nsegments > 1` splits the same trajectory into several files on
# forced keyframes (a segmented run). Writes into `dir`; returns the basename(s) and the
# ground-truth closure `expected(i; skip, offset)`: the stored-frame 1-based (row, col) of the
# disc center at sample i, where sample i reads global frame `offset + (i − 1)·skip` (skip =
# video fps ÷ requested fps).
function make_target_video(dir, name; width = 100, height = 100, sar = 1//1, fps = 25, duration = 2,
        target_width = 10, darker_target = true, row = 50, col = 55, nsegments = 1)
    A = width / 2.5
    target_c, bkgd_c = darker_target ? (0, 255) : (255, 0)
    w2 = round(Int, width / sar)
    sarg = "$(numerator(sar))/$(denominator(sar))"
    vf = "geq=lum='if(lt(sqrt((X-$col+$A*sin(0.5*PI*N/$fps))^2+(Y-$row)^2),$(target_width/2)),$target_c,$bkgd_c)':cb=128:cr=128,scale=$w2:$height,setsar=$sarg"
    # -qp 0: lossless — the analytic ground truth stays exact, with no encoder noise around the disc
    src = `-y -loglevel error -f lavfi -i color=white:s=$(width)x$(height):d=$duration:r=$fps -vf $vf -pix_fmt yuv420p -qp 0`
    files = if nsegments == 1
        FFMPEG.ffmpeg_exe(`$src $(joinpath(dir, "$name.mp4"))`)
        ["$name.mp4"]
    else
        T = duration / nsegments
        kf = "expr:gte(t,n_forced*$T)"
        FFMPEG.ffmpeg_exe(`$src -force_key_frames $kf -f segment -segment_time $T $(joinpath(dir, name * "_%02d.mp4"))`)
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

# ---------------------------------------------------------------------------
# CSV building against the including module's HEADER.
# ---------------------------------------------------------------------------

csvcell(::Missing) = ""
function csvcell(x)
    s = x isa AbstractString ? String(x) : string(x)
    (occursin(',', s) || occursin('"', s)) ? string('"', replace(s, '"' => "\"\""), '"') : s
end

function write_csv(path, rows, header)
    open(path, "w") do io
        println(io, join(header, ","))
        for r in rows
            println(io, join(csvcell.(r), ","))
        end
    end
    path
end

# A kwarg not in `header` would otherwise be dropped silently, quietly testing nothing.
function buildrow(header; kw...)
    unknown = setdiff(string.(keys(kw)), header)
    @assert isempty(unknown) "unknown CSV column/s in test row: $unknown"
    return [get(kw, Symbol(c), missing) for c in header]
end

# Baseline-row merging: `row` is each suite's `buildrow(HEADER; ...)` wrapper.
_merge(base; kw...) = row(; merge(base, values(kw))...)

# ---------------------------------------------------------------------------
# Run + assert.
# ---------------------------------------------------------------------------

"Like `check`, but also capture what the load prints to stdout. Returns (result, output). Routed
through a temp file because redirect_stdout needs a real file descriptor, not an IOBuffer."
function load_capturing(name, rows; strict = false)
    mktemp() do path, io
        result = redirect_stdout(() -> check(name, rows; strict), io)
        flush(io)
        result, read(path, String)
    end
end

# A load with issues returns a DataFrame carrying :issues (non-strict); a clean one returns the
# built objects, so anything that isn't a DataFrame is unflagged by definition.
flagged(x, r, sub) = x isa AbstractDataFrame && any(m -> occursin(sub, m), x.issues[r])
