# ffmpeg command/filter string builders. These are pure constructors — no process is spawned.

@testset "ffmpeg command builders" begin

    @testset "_vf filter selection" begin
        @test R._vf(missing, missing) === missing                        # no deinterlace, no blur
        @test R._vf(missing, 2.0) == "gblur=sigma=2.0"                   # blur only
        @test R._vf(true, missing) == "yadif=1"                          # deinterlace only
        @test R._vf(true, 2.0) == "yadif=1,gblur=sigma=2.0"              # both, in order
        # yadif = false means progressive footage: it must NOT deinterlace (VerifyRectifications
        # probes yadif as a Bool, so false is the common case — it used to hit the yadif branch)
        @test R._vf(false, missing) === missing
        @test R._vf(false, 2.0) == "gblur=sigma=2.0"
        # blur = 0 means no blur (VerifyRectifications' convention): no sigma-0 no-op filter
        @test R._vf(missing, 0.0) === missing
        @test R._vf(false, 0) === missing
        @test R._vf(true, 0.0) == "yadif=1"
    end

    @testset "_cmd" begin
        # Inspect `.exec` (the program + argument vector) rather than `string(cmd)`: the command now
        # interpolates the env-baked `FFMPEG.ffmpeg()` Cmd, so its string form also dumps the whole
        # environment — `.exec` is the clean, env-free view of the actual arguments.
        c = R._cmd("video.mp4", 1.5, missing)
        @test c isa Cmd
        args = c.exec
        @test occursin("ffmpeg", first(args))   # resolves to the (absolute-path) ffmpeg executable
        @test "video.mp4" in args
        @test "-ss" in args && "1.5" in args     # seek timestamp
        @test "-frames:v" in args
        @test "rawvideo" in args
        @test !("-vf" in args)                   # no filter clause when vf === missing

        c2 = R._cmd("video.mp4", 1.5, "yadif=1")
        @test "-vf" in c2.exec
        @test "yadif=1" in c2.exec
    end

    @testset "_cmd bakes ffmpeg env without mutating global ENV" begin
        # The non-do-block `FFMPEG.ffmpeg()` bakes PATH/LD_LIBRARY_PATH into the Cmd via setenv and
        # never touches the process-global ENV — this is what makes the builders race-free under the
        # nested tmap concurrency (replacing the old snapshot/addenv machinery).
        keys_before = Set(keys(ENV))
        ldpath_before = get(ENV, "LD_LIBRARY_PATH", nothing)
        c = R._cmd("video.mp4", 1.5, missing)
        @test c.env !== nothing                       # adjusted runtime env baked into the Cmd
        @test Set(keys(ENV)) == keys_before           # building it left process-global ENV untouched...
        @test get(ENV, "LD_LIBRARY_PATH", nothing) == ldpath_before   # ...including LD_LIBRARY_PATH
    end

end
