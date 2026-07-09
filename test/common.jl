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
# forced keyframes (a segmented run). `pause = (t1, t2)` freezes the trajectory between those
# seconds (the disc sits perfectly still, then resumes where it left off) — the long-stationary
# target that used to be absorbed into the tracker's background model. Writes into `dir`; returns
# the basename(s) and the ground-truth closure `expected(i; skip, offset)`: the stored-frame
# 1-based (row, col) of the disc center at sample i, where sample i reads global frame
# `offset + (i − 1)·skip` (skip = video fps ÷ requested fps).
function make_target_video(dir, name; width = 100, height = 100, sar = 1//1, fps = 25, duration = 2,
        target_width = 10, darker_target = true, row = 50, col = 55, nsegments = 1, pause = nothing)
    A = width / 2.5
    target_c, bkgd_c = darker_target ? (0, 255) : (255, 0)
    w2 = round(Int, width / sar)
    sarg = "$(numerator(sar))/$(denominator(sar))"
    # the frame index driving the trajectory: identity, or frozen at p1 for the pause's span
    p1, p2 = isnothing(pause) ? (0, 0) : round.(Int, pause .* fps)
    Nexpr = isnothing(pause) ? "N" : "if(lt(N,$p1),N,if(lt(N,$p2),$p1,N-($p2-$p1)))"
    freeze(N) = isnothing(pause) ? N : (N < p1 ? N : (N < p2 ? p1 : N - (p2 - p1)))
    vf = "geq=lum='if(lt(sqrt((X-$col+$A*sin(0.5*PI*($Nexpr)/$fps))^2+(Y-$row)^2),$(target_width/2)),$target_c,$bkgd_c)':cb=128:cr=128,scale=$w2:$height,setsar=$sarg"
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
        N = freeze(offset + (i - 1) * skip)
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

# ---------------------------------------------------------------------------
# Video probing (ffprobe) — for asserting on produced (diagnostic) videos.
# ---------------------------------------------------------------------------

"Facts of `file`'s first video stream: frame size, real frame count, declared fps, duration
(NaN when the container doesn't store one, e.g. MPEG-TS)."
function probe_stream(file)
    fields = Dict{String, String}()
    for l in eachline(pipeline(`$(FFMPEG.ffprobe()) -v error -select_streams v:0 -count_frames -show_entries stream=width,height,nb_read_frames,avg_frame_rate,duration -of default=noprint_wrappers=1 $file`))
        isempty(l) && continue
        k, v = split(l, '='; limit = 2)
        fields[k] = v
    end
    num, den = parse.(Int, split(fields["avg_frame_rate"], '/'))
    return (; width = parse(Int, fields["width"]), height = parse(Int, fields["height"]),
        nframes = parse(Int, fields["nb_read_frames"]), fps = num / den,
        duration = something(tryparse(Float64, get(fields, "duration", "")), NaN))
end

"Per-frame sizes (a Set of (w, h)) plus the packet PTS and DTS sequences in file (= decode)
order — for asserting a single resolution and sane timestamps across concatenated segments.
Note B-frames make PTS legitimately non-monotonic in decode order; DTS must be monotonic and
every PTS unique."
function probe_frames(file)
    sizes = Set{NTuple{2, Int}}()
    for l in eachline(pipeline(`$(FFMPEG.ffprobe()) -v error -select_streams v:0 -show_frames -show_entries frame=width,height -of csv=p=0 $file`))
        isempty(l) && continue
        w, h = parse.(Int, split(l, ',')[1:2])
        push!(sizes, (w, h))
    end
    pts = Int[]
    dts = Int[]
    for l in eachline(pipeline(`$(FFMPEG.ffprobe()) -v error -select_streams v:0 -show_entries packet=pts,dts -of csv=p=0 $file`))
        isempty(l) && continue
        parts = split(l, ',')
        push!(pts, parse(Int, parts[1]))
        push!(dts, parse(Int, parts[2]))
    end
    return sizes, pts, dts
end
