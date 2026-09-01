# `ShareIO` — the one retry loop in the package, the rule deciding what may be retried, and the
# error the two subprocess paths raise. The commands here are trivial shell utilities, not ffmpeg:
# what is under test is the retry/rethrow policy and the reporting, not decoding.

module ShareIOTests

using Test
using Fromage: ShareIO

const S = ShareIO

@testset "ShareIO" begin

    grab(f) = try f(); nothing catch e; e end
    share_failed = grab(() -> S.capture(`false`, "it failed"; tries = 1))
    io_error     = grab(() -> read(`__no_such_executable__`))   # spawn failure
    system_error = grab(() -> read("/nonexistent/nope", 6))     # file-level failure

    @testset "istransient classifies what may be retried" begin
        @test share_failed isa S.ShareReadError && S.istransient(share_failed)
        @test io_error isa Base.IOError && S.istransient(io_error)
        @test system_error isa SystemError && S.istransient(system_error)

        # Not transient, and the whole point of #25: a bare `catch` swallowed Ctrl-C for the entire
        # backoff sequence. A caller's bug must surface at once, too.
        @test !S.istransient(InterruptException())
        @test !S.istransient(MethodError(identity, ()))
        @test !S.istransient(ErrorException("boom"))

        # VideoIO cannot tell a share failure from a broken file — both are a bare ErrorException —
        # so its callers widen the rule, and only they do.
        @test S.videoio_transient(ErrorException("boom"))
        @test S.videoio_transient(share_failed)
        @test !S.videoio_transient(InterruptException())
    end

    @testset "a failure carries the command's own words, not a guess" begin
        # The bug this replaced: a `ProcessFailedException` holds an exit code and nothing else, so
        # a share that dropped the connection under an open() was reported as a corrupt file.
        # stderr is the only thing that tells those apart, so it must survive.
        e = grab(() -> S.capture(`sh -c 'echo "Resource temporarily unavailable" >&2; exit 245'`,
                                 "ffmpeg could not read the frame at 12.5s"; tries = 1))
        @test e isa S.ShareReadError
        @test e.exitcode == 245
        @test e.signal == 0
        @test e.message == "Resource temporarily unavailable"
        msg = sprint(showerror, e)
        @test occursin("ffmpeg could not read the frame at 12.5s", msg)
        @test occursin("Resource temporarily unavailable", msg)
        # and it stays short — the whole reason the old code substituted a canned string was that
        # showerror on a ProcessFailedException dumps the env-baked Cmd, some 8 kB of it.
        @test length(msg) < 200
    end

    @testset "the transient and the genuinely broken are told apart" begin
        # The two real messages, verbatim from the lab share and from the corrupt fixture. Before
        # this change both arrived as a bare ProcessFailedException and were reported identically,
        # as "the file is corrupt" — which was a guess, and for the share a wrong one. The noisy
        # "[in#0 @ 0xADDR]" prefix and the restating follow-up lines are dropped.
        share = grab(() -> S.capture(
            `sh -c 'printf "[in#0 @ 0x1bc6a800] Error opening input: Resource temporarily unavailable\nError opening input file /a/b.MP4.\n" >&2; exit 245'`,
            "ffmpeg could not read the frame at 1.0s"; tries = 1))
        broken = grab(() -> S.capture(
            `sh -c 'printf "[in#0 @ 0x8755b40] moov atom not found\nError opening input file /a/c.MP4.\n" >&2; exit 183'`,
            "ffmpeg could not read the frame at 1.0s"; tries = 1))
        @test share.message == "Error opening input: Resource temporarily unavailable"
        @test broken.message == "moov atom not found"
        @test sprint(showerror, share) != sprint(showerror, broken)
        @test !occursin("0x", sprint(showerror, share))        # the address is noise
        @test !occursin("/a/b.MP4", sprint(showerror, share))  # the report already names the file
    end

    @testset "a killed reader names its signal" begin
        # `exit -1` is what a signalled process reports, and it is uninformative. 137 (SIGKILL, the
        # OOM killer's signature) must be legible: 48 concurrent decoders against 27 GiB files is
        # exactly the shape that would provoke it, and it must never be confused with the share.
        #
        # A signal is the one POSIX thing in this module, so this is the one test that has to fork.
        # Windows has no `termsignal` — Julia reports 0 there — and MSYS's `sh` surfaces its own
        # kill as the raw wait status (9 << 8 = 2304) in the exit code instead. The share is a
        # Linux mount and the signal branch is what production exercises; all Windows owes us is
        # that the kill still arrives as a legible `ShareReadError` rather than a silent success.
        e = grab(() -> S.capture(`sh -c 'kill -9 $$'`, "ffmpeg could not read it"; tries = 1))
        @test e isa S.ShareReadError
        if Sys.isunix()
            @test e.signal == 9
            @test occursin("killed by signal 9", sprint(showerror, e))
        else
            @test e.signal == 0
            @test e.exitcode != 0
            @test occursin("ffmpeg could not read it", sprint(showerror, e))
        end
    end

    @testset "a persistent failure propagates after the last try" begin
        @test_throws S.ShareReadError S.capture(`false`, "it failed"; tries = 2)
    end

    @testset "retries actually happen, with backoff" begin
        # What this is about is the ATTEMPT COUNT, so count attempts instead of inferring them
        # from elapsed time. The count is asserted on `withretry`, which is where retrying is
        # implemented — `capture` is a one-line delegation to it — so this needs no subprocess and
        # makes no assumption about the platform's shell.
        n = Ref(0)
        @test_throws SystemError S.withretry(; tries = 3) do
            n[] += 1
            throw(SystemError("transient", 11))
        end
        @test n[] == 3

        # `capture`'s own retrying is covered through the clock, which is the only way the sleeps
        # are observable: with no backoff three `false` spawns land near zero, so 0.3s (against an
        # expected 0.2 + 0.4) catches a removed backoff with room to spare. The previous version
        # asserted `t ≥ 0.6` — the exact sum, with no margin — and a test of "did it retry" should
        # not sit on the scheduler's exact output. It deliberately does NOT pin the schedule:
        # src/shareio.jl states that, and DESIGN-HISTORY says why those values were chosen.
        t = @elapsed @test_throws S.ShareReadError S.capture(`false`, "it failed"; tries = 3)
        @test t ≥ 0.3
    end

    @testset "a non-transient failure is not retried" begin
        # A MethodError is a caller's bug, not a flaky share, so it must escape on the FIRST
        # attempt. Asserted by counting calls rather than by timing the escape: the old
        # `t < 0.2` measured a fresh `withretry` specialisation, so first-call compilation sat
        # inside the measurement, and it would have passed a version that retried quickly.
        n = Ref(0)
        @test_throws MethodError S.withretry() do
            n[] += 1
            nothing + nothing
        end
        @test n[] == 1
    end

    @testset "withretry stops as soon as it succeeds" begin
        n = Ref(0)
        # fails twice, then succeeds — three calls total, and the value comes back
        v = S.withretry(; tries = 4) do
            n[] += 1
            n[] < 3 && throw(SystemError("transient", 11))
            :ok
        end
        @test v === :ok
        @test n[] == 3
    end

    @testset "a successful read returns the bytes" begin
        @test S.capture(`echo hi`, "it failed") == codeunits("hi\n")
    end

    @testset "stdout larger than a pipe buffer does not deadlock" begin
        # A frame is ~2 MB, well past the 64 KB a pipe holds, so stdout and stderr must be drained
        # concurrently with the wait. Draining them in sequence deadlocks against a writer blocked
        # on a full pipe — which would hang the whole rectification stage, not fail it.
        n = 1_000_000
        @test length(S.capture(`sh -c "head -c $n /dev/zero"`, "it failed")) == n
    end

end

end
