# Experiment 1 (#293): do synthetic sar ≠ 1 files probe like anamorphic media, through every probe
# Fromage has (rectifications gateway, runs gateway, tracker's VideoIO), and do they round-trip
# pixel-exactly and address frames as intrinsic_start/stop/extrinsic expect?
using Fromage
using FFMPEG: FFMPEG
using VideoIO: VideoIO
const VRect = Fromage.VerifyRectifications
const VRuns = Fromage.VerifyRuns
const R = Fromage.Rectifications

dir = mktempdir()
const FPS = 10
const NF = 6

pattern(w, h, k) = UInt8[mod(i + 3j + 50k, 256) for j in 0:(h - 1), i in 0:(w - 1)]  # (row, col) = (h, w)

function rawframes(w, h)
    io = IOBuffer()
    for k in 0:(NF - 1)
        write(io, permutedims(pattern(w, h, k)))   # raw video is row-major: width varies fastest
    end
    return take!(io)
end

ff(args) = FFMPEG.ffmpeg_exe(`-y -loglevel error $args`)

function encode(path, w, h, sarstr, codecargs; vf = "setsar=$sarstr", extra = ``)
    raw = joinpath(dir, "in_$(w)x$h.raw")
    isfile(raw) || write(raw, rawframes(w, h))
    vfargs = isempty(vf) ? `` : `-vf $vf`
    ff(`-f rawvideo -pix_fmt gray -s $(w)x$h -r $FPS -i $raw $vfargs $codecargs $extra $path`)
    return path
end

x264(pix) = `-c:v libx264 -qp 0 -pix_fmt $pix`

function variants(w, h, sarstr, tag)
    out = Pair{String, String}[]
    push!(out, "x264 yuv420p mp4, setsar (Fixtures' route)" => encode(joinpath(dir, "$tag-a.mp4"), w, h, sarstr, x264("yuv420p")))
    push!(out, "x264 gray mp4, setsar" => encode(joinpath(dir, "$tag-b.mp4"), w, h, sarstr, x264("gray")))
    push!(out, "ffv1 gray mkv, setsar" => encode(joinpath(dir, "$tag-c.mkv"), w, h, sarstr, `-c:v ffv1 -pix_fmt gray`))
    # bitstream only: encode square, then rewrite the H.264 VUI with a bitstream filter
    sq = encode(joinpath(dir, "$tag-sq.h264"), w, h, "1", x264("yuv420p"); vf = "")
    num, den = split(sarstr, '/')
    bs = joinpath(dir, "$tag-d.mp4")
    ff(`-i $sq -c copy -bsf:v h264_metadata=sample_aspect_ratio=$num/$den $bs`)
    push!(out, "x264 VUI only (h264_metadata bsf), mp4" => bs)
    # container only: square bitstream, sar declared by the muxer via -aspect on a stream copy
    dar = w * parse(Int, num) // (h * parse(Int, den))
    ct = joinpath(dir, "$tag-e.mp4")
    ff(`-i $sq -c copy -aspect $(numerator(dar)):$(denominator(dar)) $ct`)
    push!(out, "x264 square VUI, container-only -aspect (mp4 pasp)" => ct)
    ctk = joinpath(dir, "$tag-f.mkv")
    ff(`-i $sq -c copy -aspect $(numerator(dar)):$(denominator(dar)) $ctk`)
    push!(out, "x264 square VUI, container-only -aspect (mkv)" => ctk)
    # HDV-style MPEG-2 transport stream (lossy; probe only)
    ts = encode(joinpath(dir, "$tag-g.ts"), w, h, sarstr, `-c:v mpeg2video -q:v 2 -pix_fmt yuv420p`)
    push!(out, "mpeg2video in mpegts (HDV-style, lossy)" => ts)
    return out
end

ffprobe_sar(f) = strip(read(`$(FFMPEG.ffprobe()) -v error -select_streams v:0 -show_entries stream=sample_aspect_ratio,display_aspect_ratio,field_order,pix_fmt -of csv=p=0 $f`, String))

function frame_index(file, t, w, h)
    img = try
        R._frame_at(file, t, missing, w, h)            # exactly the read corner detection makes
    catch e
        e isa DimensionMismatch || rethrow()
        return :no_frame
    end
    errs = [maximum(abs.(Int.(img) .- Int.(pattern(w, h, k)))) for k in 0:(NF - 1)]
    k = argmin(errs) - 1
    return (k, errs[k + 1])
end

for (w, h, sarstr, tag) in ((1440, 1080, "4/3", "hdv"), (1920, 540, "1/2", "field"))
    println("\n=== stored $(w)×$h, sar $sarstr ===")
    vs = variants(w, h, sarstr, tag)
    for (name, f) in vs
        vr = VRect.probe_video(f)
        vu = VRuns.probe_video(f)
        vio = VideoIO.openvideo(VideoIO.aspect_ratio, f)
        println(rpad(name, 58), " ffprobe=", ffprobe_sar(f))
        println("    VerifyRectifications.probe_video: ", vr isa String ? vr : (vr.width, vr.height, vr.aspect, vr.yadif))
        println("    VerifyRuns.probe_video:           ", vu isa String ? vu : (vu.width, vu.height, vu.sar, vu.fps))
        println("    VideoIO.aspect_ratio (tracker):   ", vio)
    end
    # pixel round trip and frame addressing, on the lossless variants
    for (name, f) in vs[1:3]
        println("  round trip / addressing: ", name)
        for k in 0:(NF - 1)
            t = k / FPS
            r = [frame_index(f, tt, w, h) for tt in (t - 1.0e-3, t, t + 1.0e-3, t + 0.5 / FPS)]
            println("    k=$k  t-1ms→", r[1], "  t→", r[2], "  t+1ms→", r[3], "  t+half→", r[4])
        end
    end
end
