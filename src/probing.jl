# The ffprobe plumbing shared by the two gateways (VerifyRectifications and VerifyRuns). Both need
# the same thing from a video file — spawn one ffprobe, read its `key=value` output, report an
# unreadable file as an issue string — and differ only in which entries they ask for and what they
# derive from them. That difference stays in the gateways; only the plumbing lives here.
#
# It is its own module rather than part of `Parsing` because `Parsing` is CSV-cell machinery that
# depends on nothing but Dates, and spawning ffprobe has no business widening that.
module Probing

using FFMPEG: ffprobe

# Run one ffprobe over `file` asking for `entries` (a `-show_entries` spec), and return its output
# as a `key => value` dict — or an issue string if the file could not be read.
#
# Only the spawn is fallible in a way worth catching: ffprobe exiting nonzero on an unreadable or
# corrupt file (ProcessFailedException), or the spawn/pipe itself failing (IOError, SystemError).
# Anything else is not an unreadable video and propagates. Uses the non-do-block `ffprobe()` (an
# env-baked Cmd, so its adjusted PATH/LD_LIBRARY_PATH survive interpolation and the process-global
# ENV is never mutated — which is what makes this safe under the callers' nested tmaps); stderr is
# dropped so ffmpeg's diagnostics don't leak into the program output.
function probe_fields(file, entries)
    exe = ffprobe()
    out = try
        read(pipeline(`$exe -v error -select_streams v:0 -show_entries $entries -of default=noprint_wrappers=1 $file`,
                      stderr = devnull), String)
    catch e
        e isa ProcessFailedException || e isa Base.IOError || e isa SystemError || rethrow()
        return "issue reading from video file: $(probe_failure(e))"
    end
    fields = Dict{String, String}()
    for line in eachline(IOBuffer(out))
        occursin('=', line) || continue        # a line without a separator would not destructure
        k, v = split(line, '='; limit = 2)
        fields[k] = v
    end
    return fields
end

# `showerror` on a ProcessFailedException prints the whole failed `Cmd` — including the env-baked
# PATH and LD_LIBRARY_PATH, some 7 kB of it — and this message goes straight into the user-facing
# issues report. The exit status carries no information a user can act on either, so say what
# actually happened instead. Other failures are rare and worth printing in full.
probe_failure(::ProcessFailedException) = "ffprobe could not read it (the file is corrupt, truncated, or not a video)"
probe_failure(e) = sprint(showerror, e)

end # module Probing
