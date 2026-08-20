# Every retry in this package, and the rule deciding what may be retried, in one module.
#
# The videos live on a CIFS share that reconnects on its own schedule — about five times an hour,
# including while nobody is touching it. Under the `soft` mount option (the Linux *default*) the
# kernel hands such a reconnect to userspace as EAGAIN instead of reissuing the request itself, and
# any `open()` in flight at that moment dies: ffmpeg exits 245 having read zero bytes. Measured, it
# is rare and severe rather than steady — 820,560 reads across two 3.5 h soaks saw none at all,
# while one bad 19-second window failed 62 of 195 reads. See WHY-FRAMES-FAIL.md.
#
# Three code paths open that share — ffmpeg frame reads, ffprobe probes, and VideoIO tracking opens
# — and all three need the same treatment. They used to have one retry between them, on the
# smallest of the three, which left the ~386 probe opens and ~372 tracking opens per run with no
# protection at all. Rather than grow two more private copies of the same loop, every one of them
# now calls `withretry` here, and the two subprocess paths share `capture` outright.
#
# **This module exists to be deleted.** It compensates for a mount, not for anything in this
# package. If the share is ever made reliable — the mount is now `hard`, which is measured free but
# not yet proven against an actual episode — the retries become dead code and this file goes away
# in one piece, which is the whole reason it is one piece.
module ShareIO

export ShareReadError

# Four attempts, sleeping 0.2s, 0.4s then 0.8s. Sized against the failure it covers: the reconnect
# windows observed lasted a few seconds, and each failed attempt is itself slow (a failing open hung
# 5-15 s before erroring), so the loop spans far more wall time than the backoff alone suggests.
const TRIES = 4

"""
    ShareReadError(what, exitcode, signal, message)

A subprocess reading the share failed, carrying what it said on stderr.

`read(cmd)` raises a `ProcessFailedException` holding an exit code and nothing else — the command's
stderr goes to the terminal, where it is lost. That made a share which dropped the connection under
an `open()` indistinguishable from a genuinely broken file, and both were reported as "the file is
corrupt, truncated, or not a video"; for the share, that is false, and it sends the reader to
inspect their data instead of their mount. The message is what tells the two apart: a transient
share failure says "Resource temporarily unavailable" (EAGAIN, exit 245), a broken file says "moov
atom not found" (exit 183, which is not an errno at all but `AVERROR_INVALIDDATA` truncated).

`what` is the whole subject of the sentence — "ffmpeg could not read the frame at 12.5s" — because
the two callers name different tools.
"""
struct ShareReadError <: Exception
    what::String
    exitcode::Int
    signal::Int
    message::String
end

Base.showerror(io::IO, e::ShareReadError) =
    print(io, e.what, " (exit ", e.exitcode, ")", isempty(e.message) ? "" : ": " * e.message)

# ffmpeg and ffprobe write several lines for one failure: the first is the specific one ("moov atom
# not found"), the rest restate it and repeat the whole path. Keep the first, and strip the
# "[component @ 0xADDRESS]" prefix whose address differs on every run — these messages end up in the
# user-facing issues report, which has to stay one short sentence per row.
function first_line(s)
    for line in eachsplit(s, '\n')
        cleaned = strip(replace(line, r"^\[[^\]]*@ 0x[0-9a-f]+\]\s*" => ""))
        isempty(cleaned) || return String(cleaned)
    end
    return ""
end

# What may be retried: a failed share subprocess, and the Julia-side spawn/pipe failures. Anything
# else is not the share and must surface at once rather than after four attempts — an
# `InterruptException` above all (a bare `catch` here once ate Ctrl-C for the whole backoff
# sequence, #25), but equally a caller's bug.
istransient(e) = e isa ShareReadError || e isa Base.IOError || e isa SystemError

# VideoIO reports an unreadable file, a share failure and a seek past the end alike as a plain
# `ErrorException` — there is no exit code to inspect, as there is for the two subprocess paths.
# Callers opening video through VideoIO pass this instead of `istransient`. The price of the
# coarseness is that a genuinely broken file is retried three extra times before failing; that is
# cheap (it fails in milliseconds) and every file reaching those paths has already been probed
# successfully by a gateway. The alternative is leaving the largest open path on the share
# unprotected.
videoio_transient(e) = istransient(e) || e isa ErrorException

"""
    withretry(f; tries = TRIES, transient = istransient)

Call `f()`, retrying transient failures with exponential backoff. The last attempt is made outside
the `try`, so a persistent failure propagates as itself and the function provably never returns
`nothing`.

`transient` widens the rule for callers whose library reports share failures less precisely than a
process exit code does — see `PawsomeTracker.open_gray_video`.
"""
function withretry(f; tries = TRIES, transient = istransient)
    for i in 1:(tries - 1)
        try
            return f()
        catch e
            transient(e) || rethrow()
            sleep(0.2 * 2^(i - 1))
        end
    end
    return f()
end

# Run one command against the share, returning its stdout bytes, retrying transient failures.
# `what` labels a failure ("ffmpeg could not read the frame at 12.5s").
#
# Both pipes are drained concurrently with the wait: a frame is ~2 MB, more than a pipe buffer
# holds, so reading them in sequence would deadlock against a writer blocked on a full pipe — which
# would hang the stage rather than fail it.
function capture_once(cmd, what)
    out = Pipe()
    err = Pipe()
    proc = run(pipeline(cmd; stdout = out, stderr = err), wait = false)
    close(out.in)
    close(err.in)
    outbytes = @async read(out)
    errtext = @async read(err, String)
    wait(proc)
    bytes = fetch(outbytes)
    proc.exitcode == 0 && proc.termsignal == 0 && return bytes
    # A killed process reports exitcode -1, which says nothing; the signal is the whole story (137
    # would be the OOM killer, which 48 concurrent decoders against 27 GiB files could plausibly
    # provoke). Name it, so that failure is never mistaken for the share's.
    said = first_line(fetch(errtext))
    why = proc.termsignal == 0 ? said :
          isempty(said) ? "killed by signal $(proc.termsignal)" :
                          "killed by signal $(proc.termsignal): $said"
    throw(ShareReadError(what, Int(proc.exitcode), Int(proc.termsignal), why))
end

capture(cmd, what; tries = TRIES) = withretry(() -> capture_once(cmd, what); tries)

end # module
