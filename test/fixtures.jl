# The synthetic media every suite runs against — ffmpeg-encoded videos and the analytic ground
# truth that comes with them — plus the ffprobe readers used to assert on produced videos.
#
# A module rather than an `include`d file: the four suites share one compiled copy, and generators
# here can be shared without any of them reaching into another's scope.
module Fixtures

using FFMPEG: FFMPEG
using Statistics: mean

export make_video, make_checkerboard_video, make_corrupt_video, make_target_video,
    tracking_rmse, probe_stream, probe_frames

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

# A file ffprobe reliably refuses: the leading bytes of a real mp4, with the moov atom and all the
# media data cut off. Deterministic on purpose — the "ffprobe exits 0 but reports nothing usable"
# case is covered deliberately by the audio-only fixture in test/probing.jl, so this one always
# exercises the outright-unreadable path.
function make_corrupt_video(path)
    mktempdir() do dir
        whole = joinpath(dir, "whole.mp4")
        make_video(whole; duration = 1, size = (64, 64), rate = 5)
        write(path, read(whole)[1:500])
    end
    return path
end

# A disc whose display-space center follows x(N) = col − A·sin(0.5π·N/fps), y(N) = row (ffmpeg
# 0-based coordinates, A = width/2.5), drawn by ffmpeg's geq expression at width×height square
# pixels, then squeezed to (width/sar)×height stored pixels with setsar=sar — a genuinely
# anamorphic file when sar ≠ 1. `nsegments > 1` splits the same trajectory into several files on
# forced keyframes (a segmented run). `pause = (t1, t2)` freezes the trajectory between those
# seconds — a long-stationary target, which the background model must not absorb. Writes into
# `dir`; returns the basename(s) and the ground-truth closure `expected(i; skip, offset)`: the
# stored-frame 1-based (row, col) of the disc center at sample i, where sample i reads global frame
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

end
