# Module-level state set up in __init__: the read-concurrency semaphore.
# (The ffmpeg runtime env is no longer snapshotted — `_cmd`/`_probe` get it straight from the
# env-baked `FFMPEG.ffmpeg()`/`ffprobe()` Cmds; see test_ffmpeg_cmd.jl.)

@testset "module state" begin

    @testset "read limit semaphore" begin
        old = R.read_limit()
        try
            @test R.set_read_limit!(7) == 7
            @test R.read_limit() == 7
            @test R.set_read_limit!(3) == 3
            @test R.read_limit() == 3
        finally
            R.set_read_limit!(old)            # restore whatever __init__ / env configured
        end
        @test R.read_limit() == old
    end

end
