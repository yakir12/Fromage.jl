# `_read_frame`'s retry loop, the predicate that decides what it retries, and the error it raises.
# The commands here are trivial shell utilities, not ffmpeg — what is under test is the
# retry/rethrow policy and the reporting, not decoding.

@testset "_read_frame retry policy" begin

    # Real instances of the transient failures, produced the way `_read_frame` would meet them,
    # so the test can't drift from the actual constructors.
    grab(f) = try f(); nothing catch e; e end
    frame_failed = grab(() -> R._read_frame(`false`, "f.mp4", 1.0; tries = 1))  # ffmpeg exiting nonzero
    io_error     = grab(() -> read(`__no_such_executable__`))                   # spawn failure
    system_error = grab(() -> read("/nonexistent/nope", 6))                     # file-level failure

    @testset "_transient classifies what may be retried" begin
        @test frame_failed isa R.FrameReadError && R._transient(frame_failed)
        @test io_error isa Base.IOError && R._transient(io_error)
        @test system_error isa SystemError && R._transient(system_error)

        # Not transient, and the whole point of #25: a bare `catch` swallowed Ctrl-C for the
        # entire backoff sequence. A caller's bug must surface at once, too.
        @test !R._transient(InterruptException())
        @test !R._transient(MethodError(identity, ()))
        @test !R._transient(ErrorException("boom"))
    end

    @testset "a failure carries ffmpeg's own words, not a guess" begin
        # The bug this replaced: a `ProcessFailedException` holds an exit code and nothing else,
        # so a share that dropped the connection under an open() was reported as a corrupt file.
        # stderr is the only thing that tells those apart, so it must survive.
        e = grab(() -> R._read_frame(`sh -c 'echo "Resource temporarily unavailable" >&2; exit 245'`,
                                     "/share/vid.MP4", 12.5; tries = 1))
        @test e isa R.FrameReadError
        @test e.exitcode == 245
        @test e.message == "Resource temporarily unavailable"
        @test e.file == "/share/vid.MP4"
        msg = sprint(showerror, e)
        @test occursin("Resource temporarily unavailable", msg)
        @test occursin("12.5", msg)
        # and it stays short — the whole reason the old code substituted a canned string was that
        # showerror on a ProcessFailedException dumps the env-baked Cmd, some 8 kB of it.
        @test length(msg) < 200
    end

    @testset "the transient and the genuinely broken are told apart" begin
        # These are the two real messages, verbatim from the lab share and from the corrupt
        # fixture. Before this change both arrived as a bare ProcessFailedException and were
        # reported identically, as "the file is corrupt" — which was a guess, and for the share
        # a wrong one. ffmpeg's noisy "[in#0 @ 0xADDR]" prefix and its follow-up lines (which
        # restate the error and repeat the whole path) are dropped.
        share = grab(() -> R._read_frame(
            `sh -c 'printf "[in#0 @ 0x1bc6a800] Error opening input: Resource temporarily unavailable\nError opening input file /a/b.MP4.\n" >&2; exit 245'`,
            "b.MP4", 1.0; tries = 1))
        broken = grab(() -> R._read_frame(
            `sh -c 'printf "[in#0 @ 0x8755b40] moov atom not found\nError opening input file /a/c.MP4.\n" >&2; exit 183'`,
            "c.MP4", 1.0; tries = 1))
        @test share.message == "Error opening input: Resource temporarily unavailable"
        @test broken.message == "moov atom not found"
        @test sprint(showerror, share) != sprint(showerror, broken)
        @test !occursin("0x", sprint(showerror, share))       # the address is noise
        @test !occursin("/a/b.MP4", sprint(showerror, share)) # the report already names the file
    end

    @testset "a persistent failure propagates after the last try" begin
        # `false` always exits nonzero: transient by the predicate, so every retry is used, and the
        # final attempt (outside the try) is what throws.
        @test_throws R.FrameReadError R._read_frame(`false`, "f.mp4", 1.0; tries = 2)
    end

    @testset "retries actually happen, with backoff" begin
        # tries = 3 ⇒ two failed attempts, sleeping 0.2s then 0.4s before the last one throws.
        t = @elapsed try
            R._read_frame(`false`, "f.mp4", 1.0; tries = 3)
        catch
        end
        @test t ≥ 0.6
    end

    @testset "a non-transient failure is not retried" begin
        # `run(pipeline(42))` is a MethodError — a caller's bug, not a flaky share. It must escape
        # on the first attempt: were it (wrongly) retried, tries = 4 would sleep 0.2 + 0.4 + 0.8s.
        t = @elapsed @test_throws MethodError R._read_frame(42, "f.mp4", 1.0; tries = 4)
        @test t < 0.2
    end

    @testset "a successful read returns the bytes" begin
        @test R._read_frame(`echo hi`, "f.mp4", 1.0) == codeunits("hi\n")
    end

    @testset "stdout larger than a pipe buffer does not deadlock" begin
        # A frame is ~2 MB, well past the 64 KB a pipe holds, so stdout and stderr must be drained
        # concurrently with the wait. Draining them in sequence deadlocks against a writer blocked
        # on a full pipe — which would hang the whole rectification stage, not fail it.
        n = 1_000_000
        bytes = R._read_frame(`sh -c "head -c $n /dev/zero"`, "f.mp4", 1.0)
        @test length(bytes) == n
    end

end
