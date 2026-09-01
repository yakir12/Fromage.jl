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
            @testset "$(nameof(gateway))" begin
                issue = gateway.probe_video(audio_only)
                @test issue isa String
                @test startswith(issue, "issue reading from video file")
                @test occursin("no usable video stream", issue)
            end
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

    @testset "parse_framerate: tryparse semantics, never a throw" begin
        # ffprobe reports r_frame_rate as "num/den", or occasionally a bare number.
        @test P.parse_framerate("30000/1001") ≈ 29.97 atol = 0.01
        @test P.parse_framerate("25")   == 25.0
        @test P.parse_framerate("25/1") == 25.0
        @test P.parse_framerate("25/0") == 25.0        # undefined rate: fall back to the numerator
        # Anything unparseable is `nothing`, so probe_video reports malformed output rather than
        # letting a `parse` throw into its catch. "N/A" is the interesting case: it contains
        # a '/', so it took the fraction branch and split into ("N", "A").
        @test P.parse_framerate("N/A") === nothing
        @test P.parse_framerate("")    === nothing
        @test P.parse_framerate("abc") === nothing
        @test P.parse_framerate("1/2/3") === nothing
    end

    @testset "native_framerate: only field-coded interlacing is halved (#145)" begin
        # The shape this exists for. Field-coded interlaced footage (PAFF — AVCHD/HDV "50i")
        # reports the FIELD rate in r_frame_rate, while avg_frame_rate agrees with the frames a
        # decoder actually produces.
        paff = Dict("r_frame_rate" => "50/1", "avg_frame_rate" => "25/1", "field_order" => "tt")
        @test P.native_framerate(paff) == 25.0
        for order in ("bb", "tb", "bt")            # every interlaced order, not just the tt case
            @testset "field_order = $order" begin
                @test P.native_framerate(merge(paff, Dict("field_order" => order))) == 25.0
            end
        end
        # NTSC 60i, where neither rate is a whole number
        @test P.native_framerate(Dict("r_frame_rate" => "60000/1001",
                                      "avg_frame_rate" => "30000/1001",
                                      "field_order" => "bb")) ≈ 29.97 atol = 0.01

        # Everything else keeps r_frame_rate. Each of these is a file the looser rules break:
        # progressive 50p reports 50 and means it,
        @test P.native_framerate(Dict("r_frame_rate" => "50/1", "avg_frame_rate" => "50/1",
                                      "field_order" => "progressive")) == 50.0
        # interlaced but FRAME-coded (MBAFF) already reports the frame rate,
        @test P.native_framerate(Dict("r_frame_rate" => "25/1", "avg_frame_rate" => "25/1",
                                      "field_order" => "tt")) == 25.0
        # and an absent field_order is progressive, exactly as is_interlaced reads it.
        @test P.native_framerate(Dict("r_frame_rate" => "50/1", "avg_frame_rate" => "25/1")) == 50.0

        # avg_frame_rate only ever CONFIRMS the halving: where it is nonsense (a raw .dv stream
        # reports 60000/1 for it), undefined or absent, r_frame_rate stands.
        for avg in ("60000/1", "N/A", "0/0", "")
            @testset "avg_frame_rate = $(repr(avg))" begin
                @test P.native_framerate(Dict("r_frame_rate" => "25/1", "avg_frame_rate" => avg,
                                              "field_order" => "tt")) == 25.0
            end
        end
        # An unparseable r_frame_rate stays `nothing`, so probe_video reports malformed output.
        @test P.native_framerate(Dict("r_frame_rate" => "N/A", "field_order" => "tt")) === nothing
        @test P.native_framerate(Dict{String, String}()) === nothing
    end

    @testset "real interlaced footage that is already correct is left alone (#145)" begin
        # The regression the dict cases cannot prove: an actual interlaced file. x264 codes
        # interlacing as frame pictures, so this reports field_order=tt with r_frame_rate ==
        # avg_frame_rate == 25 — the halving must not fire on it. (No encoder here writes the
        # field-coded PAFF stream that #145 is about; that shape is pinned above.)
        ilace = joinpath(dir, "ilace.mp4")
        FFMPEG.ffmpeg_exe(`-y -loglevel error -f lavfi -i testsrc=duration=1:size=320x240:rate=50
                           -vf interlace -flags +ildct+ilme -pix_fmt yuv420p $ilace`)
        f = P.probe_fields(ilace, "stream=r_frame_rate,avg_frame_rate,field_order")
        @test P.is_interlaced(f)                   # it really is interlaced footage...
        @test P.native_framerate(f) == 25.0        # ...and 25 is already its frame rate
    end
end

end
