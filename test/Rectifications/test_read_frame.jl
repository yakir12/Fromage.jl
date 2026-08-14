# `_read_frame`'s retry loop and the predicate that decides what it retries. The commands here are
# trivial shell utilities, not ffmpeg — what is under test is the retry/rethrow policy, not decoding.

@testset "_read_frame retry policy" begin

    # Real instances of the three transient failures, produced the way `_read_frame` would meet
    # them, so the test can't drift from the actual constructors.
    grab(f) = try f(); nothing catch e; e end
    process_failed = grab(() -> read(`false`))                 # ffmpeg exiting nonzero
    io_error       = grab(() -> read(`__no_such_executable__`))# spawn failure
    system_error   = grab(() -> read("/nonexistent/nope", 6))  # file-level failure

    @testset "_transient classifies what may be retried" begin
        @test process_failed isa ProcessFailedException && R._transient(process_failed)
        @test io_error isa Base.IOError && R._transient(io_error)
        @test system_error isa SystemError && R._transient(system_error)

        # Not transient, and the whole point of the change: a bare `catch` swallowed Ctrl-C for the
        # entire backoff sequence (issue #25). A caller's bug must surface at once, too.
        @test !R._transient(InterruptException())
        @test !R._transient(MethodError(identity, ()))
        @test !R._transient(ErrorException("boom"))
    end

    @testset "a persistent failure propagates after the last try" begin
        # `false` always exits nonzero: transient by the predicate, so every retry is used, and the
        # final attempt (outside the try) is what throws.
        @test_throws ProcessFailedException R._read_frame(`false`; tries = 2)
    end

    @testset "retries actually happen, with backoff" begin
        # tries = 3 ⇒ two failed attempts, sleeping 0.2s then 0.4s before the last one throws.
        t = @elapsed try
            R._read_frame(`false`; tries = 3)
        catch
        end
        @test t ≥ 0.6
    end

    @testset "a non-transient failure is not retried" begin
        # `read(42)` is a MethodError — a caller's bug, not a flaky share. It must escape on the
        # first attempt: were it (wrongly) retried, tries = 4 would sleep 0.2 + 0.4 + 0.8s first.
        t = @elapsed @test_throws MethodError R._read_frame(42; tries = 4)
        @test t < 0.2
    end

    @testset "a successful read returns the bytes" begin
        @test R._read_frame(`echo hi`) == codeunits("hi\n")
    end

end
