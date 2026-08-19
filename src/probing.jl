# The ffprobe plumbing shared by the two gateways (VerifyRectifications and VerifyRuns): spawn one
# ffprobe, read its `key=value` output, parse the individual fields it reports, and report an
# unreadable file as an issue string. Which entries to ask for, and which of them a given gateway
# cannot proceed without, stays in the gateways.
#
# Its own module rather than part of `Parsing`, which is CSV-cell machinery depending on nothing
# but Dates — spawning ffprobe has no business widening that.
module Probing

using FFMPEG: ffprobe

# Run one ffprobe over `file` asking for `entries` (a `-show_entries` spec), and return its output
# as a `key => value` dict — or an issue string if the file could not be read.
#
# Only the spawn is fallible in a way worth catching: ffprobe exiting nonzero on an unreadable or
# corrupt file, or the spawn/pipe itself failing (IOError, SystemError). Anything else is not an
# unreadable video and propagates. The non-do-block `ffprobe()` gives an env-baked Cmd, safe to
# interpolate under the callers' nested tmaps.
#
# stderr is CAPTURED rather than dropped. It used to go to devnull, which left a failure describable
# only by its exception type, and it was described as a corrupt file — the same mistake made on the
# frame-read path (see Rectifications.FrameReadError). Against the lab share the usual cause is not
# corruption at all but EAGAIN from an open() caught in a reconnect, and this stage has no retry, so
# one of them aborts the whole run while blaming the user's data. See WHY-FRAMES-FAIL.md.
function probe_fields(file, entries)
    exe = ffprobe()
    cmd = `$exe -v error -select_streams v:0 -show_entries $entries -of default=noprint_wrappers=1 $file`
    err = IOBuffer()
    out = try
        read(pipeline(cmd; stderr = err), String)
    catch e
        e isa ProcessFailedException || e isa Base.IOError || e isa SystemError || rethrow()
        return "issue reading from video file: $(probe_failure(e, String(take!(err))))"
    end
    fields = Dict{String, String}()
    for line in eachline(IOBuffer(out))
        occursin('=', line) || continue        # a line without a separator would not destructure
        k, v = split(line, '='; limit = 2)
        fields[k] = v
    end
    return fields
end

# These messages go straight into the user-facing issues report, and `showerror` on a
# ProcessFailedException prints the whole failed `Cmd` — env-baked PATH and LD_LIBRARY_PATH
# included, some 7 kB of it — with an exit status nobody can act on. So ffprobe's own first line is
# reported instead: short, and actually about this file. It distinguishes the two cases that used to
# read identically — "moov atom not found" for a file that really is truncated, "Resource
# temporarily unavailable" for a share that reconnected under the open. Other failures are rare and
# worth printing in full.
#
# `_first_line` is deliberately a copy of `Rectifications._clean_stderr` rather than a shared
# helper: this module depends on nothing but FFMPEG on purpose, and six lines of regex is a cheaper
# thing to repeat than a dependency between two modules that otherwise never meet.
function _first_line(s)
    for line in eachsplit(s, '\n')
        cleaned = strip(replace(line, r"^\[[^\]]*@ 0x[0-9a-f]+\]\s*" => ""))
        isempty(cleaned) || return String(cleaned)
    end
    return ""
end

probe_failure(::ProcessFailedException, stderr) =
    isempty(strip(stderr)) ? "ffprobe could not read it, and said nothing about why" :
                             "ffprobe could not read it: $(_first_line(stderr))"
probe_failure(e, _) = sprint(showerror, e)

# The frame size and duration, which no gateway can proceed without, or `nothing` if ffprobe
# described none of them. A miss means ffprobe *succeeded* and still could not describe a video (an
# audio-only file, or junk it recognised a container in) — not a usable video either, hence
# `no_video_stream` shares the "issue reading from video file" prefix of an outright failed read.
# Each gateway names its own required fields in the message, since it asks for its own entries.
function frame_geometry(fields)
    width    = tryparse(Int, get(fields, "width", ""))
    height   = tryparse(Int, get(fields, "height", ""))
    duration = tryparse(Float64, get(fields, "duration", ""))
    (isnothing(width) || isnothing(height) || isnothing(duration)) && return nothing
    return (; width, height, duration)
end

no_video_stream(required) = "issue reading from video file: ffprobe reported no usable video stream (missing or unparseable $required)"

# Reduce ffprobe's "num/den" r_frame_rate to a Float64, or `nothing` when the field is absent or
# unparseable (tryparse semantics, so the caller reports it as malformed output rather than a
# `parse` throwing out of the probe). A zero denominator (undefined rate) falls back to the
# numerator, keeping the value finite for the fps checks downstream.
function parse_framerate(s)
    occursin('/', s) || return tryparse(Float64, s)
    parts = split(s, '/')
    length(parts) == 2 || return nothing
    num = tryparse(Float64, parts[1])
    den = tryparse(Float64, parts[2])
    (isnothing(num) || isnothing(den)) && return nothing
    return iszero(den) ? num : num / den
end

# ffprobe reports the sample (pixel) aspect ratio as "num:den"; "N/A", "0:1" and anything else
# nonsensical mean undefined and fall back to square pixels. The display-space width of a frame is
# width × sar. VerifyRuns wants the exact ratio (it bounds-checks a pixel coordinate against
# width × sar); VerifyRectifications wants the Float64 that mirrors VideoIO.aspect_ratio.
function parse_sar(s)
    parts = split(s, ':')
    length(parts) == 2 || return 1//1
    num = tryparse(Int, parts[1])
    den = tryparse(Int, parts[2])
    (isnothing(num) || isnothing(den) || num ≤ 0 || den ≤ 0) && return 1//1
    return num // den
end

parse_sample_aspect(s) = Float64(parse_sar(s))

# ffprobe's field_order for interlaced footage; anything else (including an absent field) is
# progressive, and only interlaced footage needs deinterlacing.
const INTERLACED_FIELD_ORDERS = ("tt", "bb", "tb", "bt")

is_interlaced(fields) = get(fields, "field_order", "progressive") in INTERLACED_FIELD_ORDERS

end # module Probing
