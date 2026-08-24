# Direct PawsomeTracker coverage, over the shared synthetic-trajectory generator (test/fixtures.jl):
# ffmpeg's geq renders a disc following a known sine, encoded losslessly so the analytic ground
# truth is exact. VerifyRuns' test_tracking.jl additionally exercises track through the gateway,
# including anamorphic and scaled variants.
module PawsomeTrackerTests

using Test
using Fromage.PawsomeTracker: track
using Fromage: PawsomeTracker
const PT = PawsomeTracker

# `track` takes no keyword arguments; `track1`/`tuning`/`segments` (test/fixtures.jl) build its
# `Segment`s and `Tuning` from keywords so these tests can still name one parameter at a time.

using ..Fixtures

# The background stack is a lazily-indexed view over the array that actually holds the frames, and
# how many layers of view sit in between is nobody's business but `build_stack`'s. Unwrap to the
# storage rather than naming a depth, so a change in the pipe doesn't read as a test failure.
storage(a) = parent(a) === a ? a : storage(parent(a))

const DATADIR = mktempdir()

@testset "PawsomeTracker" begin
    base, base_exp = make_target_video(DATADIR, "pt_base")
    light, light_exp = make_target_video(DATADIR, "pt_light"; darker_target = false)
    seg, seg_exp = make_target_video(DATADIR, "pt_seg"; nsegments = 3)
    base_file = joinpath(DATADIR, only(base))

    @testset "single video, explicit start_location" begin
        # window_size left unnamed takes `get_window`'s value, as a blank csv cell does — there is
        # no second fallback inside `track` any more for it to disagree with
        _, ij = track1(base_file; start_location = (55, 50), target_width = 10)
        @test length(ij) == 50                       # the full 2 s at 25 fps
        @test tracking_rmse(ij, base_exp) < 1
    end

    @testset "start_location's declared type is what is actually supported (#18)" begin
        # The union names only what has a get_guess method behind it, so an unsupported type is
        # rejected when the Segment is built rather than dying once the video is open. Reinstating
        # CartesianIndex{2} needs a get_guess method, and this test to change.
        #
        # The rejection moved from the keyword boundary to `Segment`'s constructor when `track` lost
        # its keywords, and had to be re-asserted explicitly there: a struct field CONVERTS, and
        # Base converts a CartesianIndex to an NTuple, so the plain field type would have accepted
        # this silently — turning a (row, col) index into an (x, y) start location with the axes
        # swapped. A supported spelling still goes through untouched.
        @test_throws MethodError PT.Segment(base_file, 0.0, 2.0, CartesianIndex(50, 55))
        @test PT.Segment(base_file, 0.0, 2.0, (50, 55)).start_location == (50, 55)
        @test PT.Segment(base_file, 0.0, 2.0, missing).start_location === missing
    end

    @testset "the background stack stores frames at their decoded width (#27)" begin
        # The stack is the largest allocation in the program — a 1080p frame at background_length
        # 250 is ~494 MB as N0f8 against ~1978 MB as Float32 — and its values come from an N0f8
        # decode, so the wider type buys no precision. Nothing else in the suite catches a
        # regression here: tracking accuracy is identical either way, which is the whole point.
        vid = PT.Video(base_file, 25, 0, 2, 1.0)
        try
            stack = PT.get_stack(vid, (vid.height, vid.width), (10, 10), 10)
            @test eltype(stack) == PT.Gray{PT.N0f8}
            @test eltype(storage(stack)) == PT.Gray{PT.N0f8}   # ...and so is the array underneath

            # ...while the buffer receiving the BACKGROUND-SUBTRACTED frame stays Float32: that
            # difference is negative for a darker target, and N0f8 wraps silently rather than
            # erroring (0.2 - 0.5 == 0.702). Drop the widening in `detect` and the DoG chases
            # inverted noise — which the tracking assertions elsewhere in this file catch.
            tr = PT.Tracker(vid, true, 10, (21, 21), (vid.height, vid.width), true)
            @test eltype(tr.img) == PT.Gray{Float32}
        finally
            close(vid.vid)
        end
    end

    @testset "defaults (frame-center start)" begin
        _, ij = track1(base_file)
        @test tracking_rmse(ij, base_exp) < 1
    end

    @testset "reduced fps tracks every other frame" begin
        _, ij = track1(base_file; fps = 12.5)
        @test length(ij) == 25
        @test tracking_rmse(ij, base_exp; skip = 2) < 1
    end

    @testset "timestamps are the true times of the sampled frames (#15, #17)" begin
        # The sampler can only stride whole frames, so the rates it can actually deliver are
        # vid_fps/k. A requested fps in between must still yield a self-consistent track: sample i
        # is raw frame (i-1)*skip, so its timestamp must be start + (i-1)*skip/vid_fps — no more
        # frames than the video holds, and no timestamp implying a frame that was never read.
        v30, _ = make_target_video(DATADIR, "pt_fps30"; fps = 30, duration = 2)
        f30 = joinpath(DATADIR, only(v30))
        meta = probe_stream(f30)
        @test meta.nframes == 60                      # the fixture the cases below assume
        @test meta.fps == 30

        for requested in (30, 25, 20, 17, 12)
            skip = max(1, round(Int, meta.fps / requested))   # the stride the sampler can use
            effective = meta.fps / skip                       # the rate it therefore delivers
            ts, ij = track1(f30; fps = requested, start_location = (55, 50), target_width = 10)

            @testset "fps = $requested (skip $skip, effective $(round(effective, digits = 2)))" begin
                # must not run off the end of the video: #15's fps = 20 threw "Could not scale
                # frame". Sample i reads raw frame (i-1)*skip, so it is that index — not the
                # product of the count and the stride — which has to stay inside the video.
                @test (length(ij) - 1) * skip < meta.nframes
                @test length(ts) == length(ij)
                # each timestamp is the true time of the frame it labels — this is both issues:
                # #15 (stride and count disagreeing) and #17 (the one-frame stretch from pinning
                # the last sample to `stop`)
                @test step(ts) ≈ 1 / effective rtol = 1e-9
                @test last(ts) ≈ (length(ts) - 1) / effective rtol = 1e-9
                # and nothing may be labeled at or past the end of the window
                @test last(ts) < 2
            end
        end
    end

    @testset "lighter target on dark background" begin
        _, ij = track1(joinpath(DATADIR, only(light)); darker_target = false)
        @test tracking_rmse(ij, light_exp) < 1
    end

    @testset "segmented (vector) track" begin
        sls = Vector{Union{Missing, NTuple{2, Int}}}(missing, length(seg))
        sls[1] = (55, 50)                            # later segments continue from the previous one
        _, ij = track1(joinpath.(DATADIR, seg); start_location = sls)
        @test length(ij) == 50
        @test tracking_rmse(ij, seg_exp) < 1
    end

    @testset "background_length: no subtraction (0) and a short window (30) both track" begin
        # 0 ⇒ the DoG runs on the raw frame (the 2-slice stack only feeds detect the current
        # frame); the clean synthetic scene must track just as well without a background model
        _, ij = track1(base_file; start_location = (55, 50), target_width = 10, background_length = 0)
        @test length(ij) == 50
        @test tracking_rmse(ij, base_exp) < 1
        # a short window exercises the rolling phase (50 frames > 30-slice stack) with subtraction on
        _, ij = track1(base_file; start_location = (55, 50), target_width = 10, background_length = 30)
        @test tracking_rmse(ij, base_exp) < 1
    end

    @testset "a long-stationary target is not absorbed into the background" begin
        # the disc pauses for 17 s, far longer than the 250-frame rolling background window: without
        # protect_target the model absorbs it, erases it from the subtracted image, and the tracker
        # wanders off
        paused, paused_exp = make_target_video(DATADIR, "pt_pause"; duration = 30, pause = (8, 25))
        _, ij = track1(joinpath(DATADIR, only(paused)); start_location = (55, 50), target_width = 10)
        @test length(ij) == 750
        @test tracking_rmse(ij, paused_exp) < 1
    end

    @testset "diagnostic file plays at 2× real time" begin
        df = joinpath(DATADIR, "diag.mp4")
        track1(base_file; diagnostic_file = df)
        @test isfile(df)
        @test filesize(df) > 0
        # 50 tracked frames at 25 fps: every 2nd written, declared at 2·25/2 = 25 fps
        s = probe_stream(df)
        @test (s.width, s.height) == (640, 360)     # the fixed unrectified canvas
        @test s.nframes == 25
        @test s.fps ≈ 25
        # the contract as a property of the file itself: playing it takes real_duration/SPEEDUP
        @test s.nframes / s.fps * 2 ≈ 2 rtol = 0.01
    end

    @testset "the diagnostic opens on the first tracked frame" begin
        # `stop` trims the window to 49 samples, an ODD count — which is what makes the two
        # behaviours distinguishable. The opening frame plus every 2nd after it is cld(49, 2) = 25;
        # starting at the stride instead, as it used to, gives fld(49, 2) = 24 and drops the one
        # frame that shows where tracking began. The 50-sample case above cannot tell them apart.
        df = joinpath(DATADIR, "diag_first.mp4")
        track1(base_file; stop = 1.96, diagnostic_file = df)
        @test probe_stream(df).nframes == 25
    end

    @testset "Tuning's video_fps is what the tracker believes, not the file" begin
        # `Tuning.video_fps` is the rate the gateway probed — the tracker never reopens the video to
        # ask. Handing it the true rate must be indistinguishable from the probe; handing it a wrong
        # one must visibly change the diagnostic's declared playback rate, which is what proves the
        # field is actually used rather than quietly re-read from the file.
        df_read = joinpath(DATADIR, "vfps_read.mp4")
        df_told = joinpath(DATADIR, "vfps_told.mp4")
        df_lied = joinpath(DATADIR, "vfps_lied.mp4")
        track1(base_file; diagnostic_file = df_read)
        track1(base_file; video_fps = 25, diagnostic_file = df_told)
        # 30, not 50: at 50 the sampler picks skip = 2 and the effective rate lands back on 25, so
        # the declared rate would match by coincidence and the test would prove nothing
        track1(base_file; video_fps = 30, fps = 25, diagnostic_file = df_lied)
        @test probe_stream(df_told).fps ≈ probe_stream(df_read).fps
        @test probe_stream(df_lied).fps ≉ probe_stream(df_read).fps
    end

    @testset "diagnostic playback speed holds for a non-divisor fps (#55)" begin
        # The check above only covers a divisor rate, where requested == effective and the bug is
        # invisible. The diagnostic declares its framerate from the fps it is handed, so handing it
        # the *requested* rate made it claim the wrong speed: measured on this fixture before the
        # fix, fps = 20 declared 2.67× and fps = 12 declared 1.6×, against a contract of 2×.
        v30, _ = make_target_video(DATADIR, "diag_fps30"; fps = 30, duration = 2)
        f30 = joinpath(DATADIR, only(v30))
        for requested in (30, 25, 20, 12)
            df = joinpath(DATADIR, "diag_$requested.mp4")
            track1(f30; fps = requested, start_location = (55, 50), target_width = 10,
                   diagnostic_file = df)
            s = probe_stream(df)
            @testset "fps = $requested" begin
                @test s.nframes > 0
                # playback duration × speedup == the real duration it covers, whatever rate the
                # sampler actually delivered
                @test s.nframes / s.fps * 2 ≈ 2 rtol = 0.01
            end
        end
    end
end

end
