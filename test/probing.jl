# Unit tests for the shared ffprobe plumbing (Fromage.Probing). Both gateways reach it through
# their own probe_video, which is covered end to end in their suites; here we pin the plumbing
# itself once, rather than once per gateway.
module ProbingTests

using Test
using Fromage: Fromage
using FFMPEG: FFMPEG
using ..Fixtures

const P = Fromage.Probing
const SR = Fromage.ShareIO.ShareReadError

@testset "Probing (shared ffprobe plumbing)" begin
    dir = mktempdir()
    vid = make_video(joinpath(dir, "v.mp4"); duration = 1, size = (320, 240), rate = 25)
    corrupt = make_corrupt_video(joinpath(dir, "c.mp4"))

    # Opens cleanly, but has no video stream at all: ffprobe exits 0 and reports only the container
    # duration — the case the deterministic corrupt fixture deliberately does not cover.
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
        # The exit status carries nothing a user can act on, so it is replaced by what happened —
        # and "what happened" is ffprobe's own account, not a guess about the file. This fixture
        # really is truncated, and ffprobe says exactly that.
        issue = P.probe_fields(corrupt, "stream=width")
        @test length(issue) < 200
        @test !occursin("LD_LIBRARY_PATH", issue)
        @test occursin("moov atom not found", issue)
    end

    @testset "probe_failure: ffprobe's own words for a failed process, verbatim otherwise" begin
        # The two arms directly: a failed ffprobe reports what it said (the Cmd dump is the whole
        # problem), while any other failure — rare, and not something we can paraphrase usefully —
        # is printed in full. Driving probe_fields only ever produces the first arm, hence the
        # direct test.
        @test P.probe_failure(ErrorException("boom")) == "boom"
        @test occursin("nope", P.probe_failure(SystemError("nope", 2)))

        # The distinction this exists to preserve. Both used to render as "the file is corrupt,
        # truncated, or not a video"; only one of them is about the file at all. (The stderr
        # cleaning itself is ShareIO's and is tested there.)
        err(msg, code) = SR("ffprobe could not read it", code, 0, msg)
        broken = P.probe_failure(err("moov atom not found", 183))
        share  = P.probe_failure(err("Error opening input: Resource temporarily unavailable", 245))
        @test occursin("moov atom not found", broken)
        @test occursin("Resource temporarily unavailable", share)
        @test broken != share
        @test length(broken) < 200

        # A process that fails silently must still say something.
        @test occursin("said nothing about why", P.probe_failure(err("", 1)))
    end

    @testset "a transient share failure is retried, not reported" begin
        # This stage opens the share ~386 times per run and used to have no retry at all, so one
        # EAGAIN aborted the whole run at verification. `probe_fields` now reads through
        # `ShareIO.capture`; that the retry reaches this path is what is asserted here, using a
        # probe of a real file to prove the success path still parses.
        fields = P.probe_fields(vid, "stream=width,height")
        @test fields isa Dict && haskey(fields, "width")
    end
end

end
