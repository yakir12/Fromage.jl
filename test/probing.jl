# Unit tests for the shared ffprobe plumbing (Fromage.Probing). Both gateways reach it through
# their own probe_video, which is covered end to end in their suites; here we pin the plumbing
# itself once, rather than once per gateway.
module ProbingTests

using Test
using Fromage: Fromage
using FFMPEG: FFMPEG

const P = Fromage.Probing

@testset "Probing (shared ffprobe plumbing)" begin
    dir = mktempdir()
    vid = joinpath(dir, "v.mp4")
    FFMPEG.ffmpeg_exe(`-y -loglevel error -f lavfi -i testsrc=duration=1:size=320x240:rate=25 -pix_fmt yuv420p $vid`)
    # Deterministically unreadable: a real mp4 with everything after the first 500 bytes cut off.
    # (Random bytes were used here before — see make_corrupt_video in common.jl for why they are not.)
    corrupt = joinpath(dir, "c.mp4")
    whole = joinpath(dir, "whole.mp4")
    FFMPEG.ffmpeg_exe(`-y -loglevel error -f lavfi -i testsrc=duration=1:size=64x64:rate=5 -pix_fmt yuv420p $whole`)
    write(corrupt, read(whole)[1:500])

    # Opens cleanly, but has no video stream at all: ffprobe exits 0 and reports only the container
    # duration. This is the case that used to arrive by luck through a random fixture.
    audio_only = joinpath(dir, "audio.m4a")
    FFMPEG.ffmpeg_exe(`-y -loglevel error -f lavfi -i sine=frequency=440:duration=1 -c:a aac $audio_only`)

    @testset "a readable file yields its requested entries" begin
        f = P.probe_fields(vid, "stream=width,height:format=duration")
        @test f isa Dict{String, String}
        @test f["width"] == "320"
        @test f["height"] == "240"
        @test parse(Float64, f["duration"]) ≈ 1.0 atol = 0.2
        # only what was asked for comes back
        @test !haskey(f, "r_frame_rate")
    end

    @testset "unreadable files become issue strings, never throws" begin
        for f in (corrupt, joinpath(dir, "nope.mp4"))
            issue = P.probe_fields(f, "stream=width")
            @test issue isa String
            @test startswith(issue, "issue reading from video file")   # the prefix both gateways flag on
        end
    end

    @testset "a file with no video stream is reported, not mistaken for usable" begin
        # ffprobe *succeeds* here — it opens the file and prints the container duration — so
        # probe_fields correctly returns a dict, and it is the gateways that must notice no video
        # stream was described. Both must say so in the same family as an outright failed read: to
        # the user the file is simply not a usable video either way.
        f = P.probe_fields(audio_only, "stream=width,height:format=duration")
        @test f isa Dict{String, String}          # the probe itself did not fail...
        @test !haskey(f, "width")                 # ...it just had no video stream to describe
        for gateway in (Fromage.VerifyRectifications, Fromage.VerifyRuns)
            issue = gateway.probe_video(audio_only)
            @test issue isa String
            @test startswith(issue, "issue reading from video file")
            @test occursin("no usable video stream", issue)
        end
    end

    @testset "a failed ffprobe reports briefly, not by dumping the command" begin
        # `showerror` on a ProcessFailedException prints the entire env-baked Cmd — the full PATH
        # and LD_LIBRARY_PATH, some 7 kB — and this message lands in the user-facing issues report.
        # The exit status carries nothing a user can act on, so it is replaced by what happened.
        issue = P.probe_fields(corrupt, "stream=width")
        @test length(issue) < 200
        @test !occursin("LD_LIBRARY_PATH", issue)
        @test occursin("corrupt, truncated, or not a video", issue)
    end

    @testset "probe_failure: brief for a failed process, verbatim otherwise" begin
        # The two arms directly: a failed ffprobe is summarized (the Cmd dump is the whole problem),
        # while any other failure — rare, and not something we can paraphrase usefully — is printed
        # in full. Driving probe_fields only ever produces the first arm, hence the direct test.
        pfe = try read(`false`) catch e; e end
        @test pfe isa ProcessFailedException
        @test occursin("corrupt, truncated, or not a video", P.probe_failure(pfe))
        @test P.probe_failure(ErrorException("boom")) == "boom"
        @test occursin("nope", P.probe_failure(SystemError("nope", 2)))
    end
end

end
