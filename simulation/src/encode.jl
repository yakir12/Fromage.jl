# Lossless encoding (#289, #293): gray x264 at `-qp 0`, with the sar written by `setsar`. #293 encoded
# synthetic `sar ≠ 1` media seven ways; on this one both gateways' ffprobe and the tracker's VideoIO
# all read the sar, and the pixels round-trip exactly. The `yuv420p` route of the prototype's encoder
# (`prototype/simulated-trial:prototype/prototype_trial.jl`), fed gray frames, came back one grey
# level off: a range conversion.

using FFMPEG: FFMPEG

"""
    encode(path, frames, sar) -> path

Write `frames`, each a stored frame as [`render`](@ref) returns it (a `height × width` matrix of
`UInt8`, column-major), losslessly to the video `path` at 1 frame per second, so frame `k` (0-based)
is at `t = k` s: the timestamp Fromage's `extrinsic` and intrinsic window address it by (#293).
`sar` is the video's sample aspect ratio. Raw video is row-major, so each frame is written transposed.

When ffmpeg fails, the error carries what ffmpeg said.
"""
function encode(path, frames::AbstractVector{<:AbstractMatrix{UInt8}}, sar::Rational{<:Integer})
    isempty(frames) && throw(ArgumentError("no frames to encode"))
    height, width = size(first(frames))
    all(frame -> size(frame) == (height, width), frames) ||
        throw(ArgumentError("every frame must be $height × $width, as the first is"))
    cmd = `$(FFMPEG.ffmpeg()) -y -hide_banner -loglevel error -f rawvideo -pix_fmt gray
        -s $(width)x$height -r 1 -i pipe:0
        -vf setsar=$(numerator(sar))/$(denominator(sar)) -c:v libx264 -qp 0 -pix_fmt gray $path`
    said = IOBuffer()
    ffmpeg = open(pipeline(cmd; stderr = said), "w")
    # an ffmpeg that exits early breaks the pipe; the write's `IOError` is kept only for when ffmpeg
    # itself reports no failure, because otherwise ffmpeg's own message says why
    broken = try
        foreach(frame -> write(ffmpeg, permutedims(frame)), frames)
        nothing
    catch e
        e isa Base.IOError || rethrow()
        e
    finally
        close(ffmpeg.in)
        wait(ffmpeg)
    end
    success(ffmpeg) || error("ffmpeg could not encode $path (exit $(ffmpeg.exitcode)): ", strip(String(take!(said))))
    isnothing(broken) || throw(broken)
    return path
end
