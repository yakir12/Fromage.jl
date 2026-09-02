# Direct PawsomeTracker coverage, over the shared synthetic-trajectory generator (test/fixtures.jl):
# ffmpeg's geq renders a disc following a known sine, encoded losslessly so the analytic ground
# truth is exact. VerifyRuns' test_tracking.jl additionally exercises track through the gateway,
# including anamorphic and scaled variants.
module PawsomeTrackerTests

using Test
using Fromage.PawsomeTracker: track
using Fromage: PawsomeTracker
# `Gray`/`N0f8` through the submodule, as test/apriltag.jl does — they are not test deps.
using Fromage.PawsomeTracker: Gray, N0f8
using Random: Xoshiro
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
    # The unit-scale stack skips the WarpedView the scaled one needs. That is only sound if it
    # reads identically to the warped construction it replaces, so assert exactly that rather than
    # the presence or absence of a layer — the layer count is the mechanism, the values are the
    # claim. `storage` still has to reach the array, since every write goes through it.
    @testset "the unit-scale stack returns its stored values, unresampled" begin
        sz, n = (24, 31), 4
        pad = ((-3):(sz[1] + 3), (-3):(sz[2] + 3), 1:n)
        stack = PT.build_stack(1.0, sz, n, pad)
        frames = Gray{N0f8}.(rand(Xoshiro(20260901), N0f8, sz..., n))   # seeded: a failure must reproduce
        storage(stack) .= frames

        # The write path reaches the array through `parent(parent(...))`, so a stack with one view
        # fewer still has to land there — `parent` of an Array is that array.
        @test storage(stack) === parent(parent(stack))
        @test axes(stack) == pad
        # The claim the speedup rests on: at unit scale a read is the stored value itself, not an
        # interpolation of it. A resampling stack would return values near these, not equal to them.
        @test stack[1:sz[1], 1:sz[2], :] == frames
        @test stack[0, 0, 1] == zero(Gray{N0f8})     # padding still reads as the fill value
        # A scaled stack keeps the warp, and its canvas is the scaled one.
        @test size(PT.build_stack(0.5, sz, n, pad), 3) == n
    end

    base, base_exp = make_target_video(DATADIR, "pt_base")
    light, light_exp = make_target_video(DATADIR, "pt_light"; darker_target = false)
    seg, seg_exp = make_target_video(DATADIR, "pt_seg"; nsegments = 3)
    base_file = joinpath(DATADIR, only(base))

    @testset "single video, explicit start_location" begin
        # window_size left unnamed takes `get_window`'s value, as a blank csv cell does — there is
        # no second fallback inside `track` any more for it to disagree with
        _, ij = track1(base_file; start_location = (55, 50), target_width = 10)
        @test length(ij) == 50                       # the full 2 s at 25 fps
        @test tracking_rmse(ij, base_exp) < 0.5      # 0.139 px, identical on linux/macOS/windows
    end

    @testset "tracking is deterministic" begin
        # Same file, same Segment and Tuning, same coordinates — bit for bit, whatever
        # JULIA_NUM_THREADS is. Measured over separate processes and at 1, 2, 4, 8 and 32 threads:
        # every coordinate identical, every RMSE identical to the last Float64 digit.
        #
        # Asserted as EQUALITY, with no tolerance, and that is the point. Every other accuracy
        # assertion in the suite bounds a residual, so nondeterminism entering the threaded
        # read/detect/track path would surface as an intermittent tolerance failure that nobody
        # can reproduce. This fails immediately instead, and names the cause.
        _, a = track1(base_file; start_location = (55, 50), target_width = 10)
        _, b = track1(base_file; start_location = (55, 50), target_width = 10)
        @test a == b
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
        vid = PT.Video(base_file, 25, 25, 0, 2, 1.0)   # (native_fps, sample_fps): the file's own rate, sampled whole
        try
            stack = PT.get_stack(vid, (vid.height, vid.width), (10, 10), 10)
            @test eltype(stack) == Gray{N0f8}
            @test eltype(storage(stack)) == Gray{N0f8}   # ...and so is the array underneath

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
        @test tracking_rmse(ij, base_exp) < 0.5      # 0.144 px, identical on linux/macOS/windows
    end

    @testset "reduced sample_fps tracks every other frame" begin
        _, ij = track1(base_file; sample_fps = 12.5)
        @test length(ij) == 25
        @test tracking_rmse(ij, base_exp; skip = 2) < 0.5   # 0.158 px, identical on all three
    end

    @testset "timestamps are the true times of the sampled frames (#15, #17)" begin
        # The sampler can only stride whole frames, so the rates it can actually deliver are
        # native_fps/k. A requested sample_fps in between must still yield a self-consistent track:
        # sample i is raw frame (i-1)*skip, so its timestamp must be start + (i-1)*skip/native_fps —
        # no more frames than the video holds, and no timestamp implying a frame never read.
        v30, _ = make_target_video(DATADIR, "pt_fps30"; fps = 30, duration = 2)
        f30 = joinpath(DATADIR, only(v30))
        meta = probe_stream(f30)
        @test meta.nframes == 60                      # the fixture the cases below assume
        @test meta.fps == 30

        for requested in (30, 25, 20, 17, 12)
            skip = max(1, round(Int, meta.fps / requested))   # the stride the sampler can use
            effective = meta.fps / skip                       # the rate it therefore delivers
            ts, ij = track1(f30; sample_fps = requested, start_location = (55, 50), target_width = 10)

            @testset "sample_fps = $requested (skip $skip, effective $(round(effective, digits = 2)))" begin
                # must not run off the end of the video: #15's sample_fps = 20 threw "Could not scale
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
        @test tracking_rmse(ij, light_exp) < 0.5     # 0.144 px, identical on linux/macOS/windows
    end

    @testset "segmented (vector) track" begin
        sls = Vector{Union{Missing, NTuple{2, Int}}}(missing, length(seg))
        sls[1] = (55, 50)                            # later segments continue from the previous one
        _, ij = track1(joinpath.(DATADIR, seg); start_location = sls)
        @test length(ij) == 50
        # stays at 1: measured 0.594 px (identical on all three platforms), the largest of any
        # tracking site — the segment seams are where the tracker is genuinely least accurate, and
        # 1.7x headroom is already the tightest here. Tightening this one buys nothing and would
        # be the first to break on an ffmpeg change.
        @test tracking_rmse(ij, seg_exp) < 1
    end

    @testset "background_length: no subtraction (0) and a short window (30) both track" begin
        # 0 ⇒ the DoG runs on the raw frame (the 2-slice stack only feeds detect the current
        # frame); the clean synthetic scene must track just as well without a background model
        _, ij = track1(base_file; start_location = (55, 50), target_width = 10, background_length = 0)
        @test length(ij) == 50
        @test tracking_rmse(ij, base_exp) < 0.5      # 0.202 px, identical on linux/macOS/windows
        # a short window exercises the rolling phase (50 frames > 30-slice stack) with subtraction on
        _, ij = track1(base_file; start_location = (55, 50), target_width = 10, background_length = 30)
        @test tracking_rmse(ij, base_exp) < 1        # unmeasured cross-platform — see the probe
    end

    @testset "a long-stationary target is not absorbed into the background" begin
        # the disc pauses for 17 s, far longer than the 250-frame rolling background window: without
        # protect_target the model absorbs it, erases it from the subtracted image, and the tracker
        # wanders off
        paused, paused_exp = make_target_video(DATADIR, "pt_pause"; duration = 30, pause = (8, 25))
        _, ij = track1(joinpath(DATADIR, only(paused)); start_location = (55, 50), target_width = 10)
        @test length(ij) == 750
        @test tracking_rmse(ij, paused_exp) < 1      # unmeasured cross-platform — see the probe
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

    @testset "Tuning's native_fps is what the tracker believes, not the file" begin
        # `Tuning.native_fps` is the rate the gateway settled — the probe's, or the one runs.csv
        # declared in its place — and the tracker never opens the video to ask. base_file really
        # runs at 25 fps for 2 s (50 frames), so declaring half that must halve the sample count and
        # double the timestamp step, which is what proves the field is used rather than quietly
        # re-read from the container.
        ts, ij = track1(base_file; native_fps = 12.5)
        @test length(ij) == 25
        @test step(ts) ≈ 1 / 12.5
        # …and the diagnostic's declared playback rate follows it, since that too is derived from
        # the rate the tracker believes rather than the one the file states.
        #
        # 5, not 12.5: the writer decimates to land near DIAGNOSTIC_FPS, and at 12.5 it drops the
        # stride from 2 to 1 and declares the same 25 fps the probed rate does — matching by
        # coincidence and proving nothing.
        df_read = joinpath(DATADIR, "nfps_read.mp4")
        df_told = joinpath(DATADIR, "nfps_told.mp4")
        df_slow = joinpath(DATADIR, "nfps_slow.mp4")
        track1(base_file; diagnostic_file = df_read)
        track1(base_file; native_fps = 25, diagnostic_file = df_told)   # the truth, said out loud
        track1(base_file; native_fps = 5, diagnostic_file = df_slow)
        @test probe_stream(df_told).fps ≈ probe_stream(df_read).fps
        @test probe_stream(df_slow).fps ≉ probe_stream(df_read).fps
    end

    @testset "diagnostic playback speed holds for a non-divisor sample_fps (#55)" begin
        # The check above only covers a divisor rate, where requested == effective and the bug is
        # invisible. The diagnostic declares its framerate from the rate it is handed, so handing it
        # the *requested* rate made it claim the wrong speed: measured on this fixture before the
        # fix, sample_fps = 20 declared 2.67× and 12 declared 1.6×, against a contract of 2×.
        v30, _ = make_target_video(DATADIR, "diag_fps30"; fps = 30, duration = 2)
        f30 = joinpath(DATADIR, only(v30))
        for requested in (30, 25, 20, 12)
            df = joinpath(DATADIR, "diag_$requested.mp4")
            track1(f30; sample_fps = requested, start_location = (55, 50), target_width = 10,
                   diagnostic_file = df)
            s = probe_stream(df)
            @testset "sample_fps = $requested" begin
                @test s.nframes > 0
                # playback duration × speedup == the real duration it covers, whatever rate the
                # sampler actually delivered
                @test s.nframes / s.fps * 2 ≈ 2 rtol = 0.01
            end
        end
    end
end

end
