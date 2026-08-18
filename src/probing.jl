# The ffprobe plumbing shared by the two gateways (VerifyRectifications and VerifyRuns): spawn one
# ffprobe, read its `key=value` output, report an unreadable file as an issue string. Which entries
# to ask for, and what to derive from them, stays in the gateways.
#
# Its own module rather than part of `Parsing`, which is CSV-cell machinery depending on nothing
# but Dates — spawning ffprobe has no business widening that.
module Probing

using FFMPEG: ffprobe

# Run one ffprobe over `file` asking for `entries` (a `-show_entries` spec), and return its output
# as a `key => value` dict — or an issue string if the file could not be read.
#
# Only the spawn is fallible in a way worth catching: ffprobe exiting nonzero on an unreadable or
# corrupt file (ProcessFailedException), or the spawn/pipe itself failing (IOError, SystemError).
# Anything else is not an unreadable video and propagates. The non-do-block `ffprobe()` gives an
# env-baked Cmd, safe to interpolate under the callers' nested tmaps; stderr is dropped so ffmpeg's
# diagnostics don't leak into the program output.
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

# These messages go straight into the user-facing issues report, and `showerror` on a
# ProcessFailedException prints the whole failed `Cmd` — env-baked PATH and LD_LIBRARY_PATH
# included, some 7 kB of it — with an exit status nobody can act on. Say what happened instead.
# Other failures are rare and worth printing in full.
probe_failure(::ProcessFailedException) = "ffprobe could not read it (the file is corrupt, truncated, or not a video)"
probe_failure(e) = sprint(showerror, e)

end # module Probing
