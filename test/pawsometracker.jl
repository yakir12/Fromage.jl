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
# For `VideoIO._active_writers`: a PRIVATE name, and the only direct evidence that a diagnostic
# left nothing open (#160). An `UndefVarError` on it is a dependency rename, not a regression.
# `isopen` needs no import — it is Base's, with VideoIO methods for the writer and the reader.
using VideoIO: VideoIO
const PT = PawsomeTracker

# `track` takes no keyword arguments; `track1`/`tuning`/`segments` (test/fixtures.jl) build its
# `Segment`s and `Tuning` from keywords so these tests can still name one parameter at a time.

using ..Fixtures

# The background stack is a lazily-indexed view over the array that actually holds the frames, and
# how many layers of view sit in between is nobody's business but `build_stack`'s. Unwrap to the
# storage rather than naming a depth, so a change in the pipe doesn't read as a test failure.
storage(a) = parent(a) === a ? a : storage(parent(a))

# Finalization is `close` itself, and `close_video_out!` cannot be made to fail on demand — it frees
# its pointers in its own `finally` and no-ops on a writer already closed. So the failure is
# injected around a REAL diagnostic: the writer really is finalized, and the throw that follows is
# what a caller would see from a finalization that failed (#160). Wrapping rather than faking keeps
# the leak assertions meaningful — there is an actual writer to have leaked.
struct CloseThenFail{D}
    dia::D
end
Base.close(c::CloseThenFail) = (close(c.dia); error("injected finalization failure"))

const DATADIR = mktempdir()

@testset "PawsomeTracker" begin
    # The stack at `downscale = 1` skips the WarpedView the scaled one needs. That is only sound if it
    # reads identically to the warped construction it replaces, so assert exactly that rather than
    # the presence or absence of a layer — the layer count is the mechanism, the values are the
    # claim. `storage` still has to reach the array, since every write goes through it.
    @testset "the stack at `downscale = 1` returns its stored values, unresampled" begin
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
    # Anamorphic, both directions: sar 1/2 stores 200x100, sar 2 stores 50x100. Every other fixture
    # in this file is square at sar 1, where the two axes are interchangeable and a transposition
    # cannot show (#36).
    sar05, _ = make_target_video(DATADIR, "pt_sar05"; sar = 1//2)
    sar2, _ = make_target_video(DATADIR, "pt_sar2"; sar = 2//1)
    # Non-square, with the disc well off the diagonal. Every other trajectory fixture is 100x100
    # with the disc at (row 50, col 55): there a transposed start location lands 7 px away, a third
    # of the default search radius, so it still tracks and no assertion notices. Here row 30 and
    # col 120 cannot be confused — a transposed guess names row 120 of a 90-row frame.
    wide, wide_exp = make_target_video(DATADIR, "pt_wide"; width = 160, height = 90, row = 30, col = 120)
    wide_file = joinpath(DATADIR, only(wide))

    @testset "single video, explicit start_location" begin
        # window_size left unnamed takes `get_window`'s value, as a blank csv cell does — there is
        # no second fallback inside `track` any more for it to disagree with
        _, ij = track1(base_file; start_location = (55, 50), target_width = 10)
        @test length(ij) == 50                       # the full 2 s at 25 fps
        @test tracking_rmse(ij, base_exp) < 0.5      # 0.139 px on every platform measured
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

    @testset "Video declares no duration field (#231)" begin
        # A `Float64` span computed on construction and never read — on a struct built once per
        # segment, under `tmap`, on the tracking path. The span the tracker actually consumes is
        # the RUN's, which `VerifyRuns.run_duration` sums over a run's segments and hands to
        # `get_window`; `Video`'s constructor still forms `stop - start` for its own frame count,
        # uses it there and drops it. Reinstating the field needs a reader for it.
        @test !hasfield(PT.Video, :duration)
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

    # The anamorphic squeeze stretches ONE axis — the columns — so the search window and the matched
    # filter must both stretch along that same axis. `radii` converts the window's column extent by
    # sar; the DoG has to agree, or the two are stretched orthogonally and the filter no longer
    # matches the shape it is looking for. Measured against the disc as actually encoded rather than
    # against a formula, so the assertion cannot drift with the one it is checking. Invisible at
    # sar = 1, which is why every other fixture here misses it.
    @testset "the DoG is stretched along the same axis as the target (sar ≠ 1)" begin
        for files in (sar05, sar2)
            vid = PT.Video(joinpath(DATADIR, only(files)), 25, 25, 0, 2, 1.0)
            try
                dark = Float64.(vid.img) .< 0.5               # the target is the dark disc
                taller = count(any(dark, dims = 2)[:]) > count(any(dark, dims = 1)[:])
                tr = PT.Tracker(vid, true, 10, (21, 21), (vid.height, vid.width), true)
                @test (size(tr.kernel, 1) > size(tr.kernel, 2)) == taller
                @test (tr.radii[1] > tr.radii[2]) == taller   # the window was already right
            finally
                close(vid.vid)
            end
        end
    end

    # The three assertions below pin the display (x, y) -> scaled (row, col) conversion directly.
    # Until now it was only ever observed through a tracking RMSE, and the measured cost of getting
    # it backwards on the square fixtures is 0.139 -> 0.149 px against a tolerance of 0.5 — so every
    # existing assertion passes with the axes swapped.
    @testset "a non-square frame pins the start location's axis order" begin
        # display (x, y) = (120, 30) on a 160x90 frame. Swapped, this is row 120 of 90 rows: the
        # guess lands outside the frame, the search clamps to the wrong corner, and the track leaves
        # the disc entirely.
        _, ij = track1(wide_file; start_location = (120, 30), target_width = 10)
        @test tracking_rmse(ij, wide_exp) < 0.5
    end

    # `track` derives three pre-scaled values once per run and hands them to every segment. They
    # used to travel as three bare arguments among thirteen; six of those thirteen were `Float64`,
    # and transposing `target_width` with `initial_search_factor` at the call site passed the ENTIRE
    # tracker suite. `ScaledTuning` narrows that to one constructor; these two testsets close it.
    @testset "ScaledTuning scales exactly the three values track derives" begin
        # Asymmetric on purpose: the three fields differ from each other, the window is non-square,
        # and downscale != 1, so any transposition among them changes at least one field.
        t = PT.Tuning(10.0, (31, 21), true, 25.0, 25.0, 4.0, 0.5, 250)
        s = PT.ScaledTuning(t)
        @test s.width  == 5.0                      # downscale * target_width
        @test s.search == 2.0                      # downscale * initial_search_factor
        # (w, h) = (31, 21) -> fix_window_size -> (rows, cols) = (21, 31) -> scaled
        @test s.window == round.(Int, 0.5 .* (21, 31))
        @test s.window[1] != s.window[2]           # a transposed window would be visible
        # width and search are both Float64 and are the pair that was invisible: pin them apart
        @test s.width != s.search
    end

    @testset "a centre search is sized by initial_search_factor, not by target_width" begin
        # The behavioural half. With no start_location the tracker searches a box of
        # min(frame)/initial_search_factor around the CANVAS centre. On the 160x90 fixture the
        # centre is (45, 80) and the disc is at (30, 120), 40 columns away, so the box has to be
        # wide to contain it: initial_search_factor = 1 gives 90x90, spanning columns 35..125.
        #
        # Swap target_width and initial_search_factor and the box becomes min(90,160)/10 = 9 px
        # wide, columns 76..84 — the disc is not in it, and the tracker never finds the target.
        # That is the swap the square fixtures cannot see, because there the disc sits at the
        # centre and any box contains it.
        _, ij = track1(wide_file; start_location = missing, target_width = 10,
                       initial_search_factor = 1.0)
        @test tracking_rmse(ij, wide_exp) < 0.5
    end

    @testset "get_guess maps display (x, y) to scaled (row, col)" begin
        # Exact equality, and the two components differ, so a transposition cannot slip through on
        # tolerance the way the RMSE assertions do.
        vid = PT.Video(wide_file, 25, 25, 0, 2, 1.0)      # sar 1, downscale 1
        try
            @test PT.get_guess((120, 30), nothing, vid, false, 0, 0, false) == (30, 120)
        finally
            close(vid.vid)
        end

        # ...and at sar 1/2 the x is converted to stored columns on the way, y untouched.
        anam = PT.Video(joinpath(DATADIR, only(sar05)), 25, 25, 0, 2, 1.0)
        try
            @test anam.sar == 1//2
            @test PT.get_guess((10, 90), nothing, anam, false, 0, 0, false) == (90, 20)
        finally
            close(anam.vid)
        end
    end

    @testset "fix_window_size transposes (width, height) into (rows, cols)" begin
        @test PT.fix_window_size((31, 21)) == (21, 31)   # the csv gives (w, h); the tracker wants (rows, cols)
        @test PT.fix_window_size((21, 31)) == (31, 21)   # ...and the other way round
        @test PT.fix_window_size(20) == (21, 21)         # a scalar side length, oddified
    end

    @testset "defaults (frame-center start)" begin
        _, ij = track1(base_file)
        @test tracking_rmse(ij, base_exp) < 0.5      # 0.144 px on every platform measured
    end

    @testset "reduced sample_fps tracks every other frame" begin
        _, ij = track1(base_file; sample_fps = 12.5)
        @test length(ij) == 25
        @test tracking_rmse(ij, base_exp; skip = 2) < 0.5   # 0.158 px on every platform measured
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
        @test tracking_rmse(ij, light_exp) < 0.5     # 0.144 px on every platform measured
    end

    @testset "segmented (vector) track" begin
        sls = Vector{Union{Missing, NTuple{2, Int}}}(missing, length(seg))
        sls[1] = (55, 50)                            # later segments continue from the previous one
        _, ij = track1(joinpath.(DATADIR, seg); start_location = sls)
        @test length(ij) == 50
        # stays at 1: measured 0.594 px, the largest of any
        # tracking site — the segment seams are where the tracker is genuinely least accurate, and
        # 1.7x headroom is already the tightest here. Tightening this one buys nothing and would
        # be the first to break on an ffmpeg change.
        @test tracking_rmse(ij, seg_exp) < 1
    end

    @testset "two windows of one file: the run's clock closes the gap up (#153)" begin
        # A run may be several windows of ONE file — that is how an untrackable stretch is left
        # out. The run's timeline is one clock: it starts at the FIRST segment's `start` and
        # advances one sampling interval per tracked frame, so the second window's own `start`
        # (1.2 s, a time in the same file) never appears and the 0.4 s left out is closed up.
        # Nothing else asserts the timestamps of a multi-segment run.
        ts, ij = track1([base_file, base_file]; start = [0.4, 1.2], stop = [0.8, 1.6],
                        start_location = [(55, 50), missing])
        # 25 fps, sampled at its own rate: 10 frames per 0.4 s window.
        @test length(ts) == 20
        @test length(ij) == length(ts)
        @test first(ts) == 0.4                   # the first segment's start, not the file's zero
        @test step(ts) == 1 / 25
        @test last(ts) ≈ 0.4 + 19 / 25           # continuous: no jump where the gap was
    end

    @testset "background_length: no subtraction (0) and a short window (30) both track" begin
        # 0 ⇒ the DoG runs on the raw frame (the 2-slice stack only feeds detect the current
        # frame); the clean synthetic scene must track just as well without a background model
        _, ij = track1(base_file; start_location = (55, 50), target_width = 10, background_length = 0)
        @test length(ij) == 50
        @test tracking_rmse(ij, base_exp) < 0.5      # 0.202 px on every platform measured
        # a short window exercises the rolling phase (50 frames > 30-slice stack) with subtraction on
        _, ij = track1(base_file; start_location = (55, 50), target_width = 10, background_length = 30)
        @test tracking_rmse(ij, base_exp) < 0.5      # 0.139 px on linux/windows/macOS
    end

    @testset "a long-stationary target is not absorbed into the background" begin
        # the disc pauses for 17 s, far longer than the 250-frame rolling background window: without
        # protect_target the model absorbs it, erases it from the subtracted image, and the tracker
        # wanders off
        paused, paused_exp = make_target_video(DATADIR, "pt_pause"; duration = 30, pause = (8, 25))
        _, ij = track1(joinpath(DATADIR, only(paused)); start_location = (55, 50), target_width = 10)
        @test length(ij) == 750
        @test tracking_rmse(ij, paused_exp) < 0.5    # 0.209 px on linux/windows/macOS
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

    # #149: the reader is closed on every path out of `Video`'s construction. Unlike the diagnostic
    # writer of #160, the fallible steps here CANNOT be reordered before the open — `read`,
    # `gettime`, `seek` and `aspect_ratio` are reads of the reader itself, and on the share they are
    # exactly the calls that fail (WHY-FRAMES-FAIL.md). The guard is the whole mechanism.
    @testset "a failed Video construction closes its reader" begin
        # `downscale = NaN` fails at the `WarpedView` extent — `ImageTransformations._autorange`
        # rounds the transformed corners — and that line consumes `img`, the frame `read(vid)`
        # returned. So the injection is after the open by construction, not by luck: moving it
        # earlier would mean moving the decode earlier, which needs the reader anyway. (The
        # arithmetic steps throw too, but they sit at the top and a later edit could lift them above
        # the open, turning this green for the wrong reason.)
        @test_throws InexactError PT.Video(base_file, 25, 25, 0, 2, NaN)

        # …and the reader really is gone. An unclosed `VideoReader` holds exactly one descriptor,
        # so leaks count: before the fix, 15 failures leaked 15 descriptors — "exhaust OS
        # descriptors over a large batch" (#149) in miniature, and the repeated-failure batch the
        # issue asks to verify. Linux only: /proc is where a process can see its own descriptors.
        #
        # GC OFF for the loop, and this is load-bearing rather than tidy. `AVFormatContextPtr`
        # carries a finalizer that closes the input, so a collection reclaims leaked readers and the
        # count comes back clean — measured: a leaking build shows +15 with a quiet heap and +0 once
        # the loop allocates enough to trigger a GC. Without this the assertion would pass against
        # the very bug it exists to catch, on any machine that collects at the wrong moment.
        if Sys.islinux()
            nfd() = length(readdir("/proc/self/fd"))
            GC.gc()
            before = nfd()
            GC.enable(false)
            try
                for _ in 1:15
                    try
                        PT.Video(base_file, 25, 25, 0, 2, NaN)
                    catch e
                        e isa InexactError || rethrow()
                    end
                end
                # `==`, not `<=`: with the collector off nothing can close a descriptor behind us,
                # so the count can only have grown, and it must not have. `GC.enable` is
                # process-global — fine while this file runs sequentially, worth revisiting if the
                # testset ever moves under `tforeach`.
                @test nfd() == before
            finally
                GC.enable(true)
            end
        end

        # The guard, not just the close. Every assertion above still passes if `warn_on_failure` is
        # swapped for a bare `close(vid)` — so this pins the other half of the mechanism, the half
        # that keeps a failing cleanup from replacing the failure on its way to the caller. A real
        # reader's `close` cannot be made to throw on demand, so the claim is made of the helper
        # both closes go through.
        err = @test_logs (:warn,) match_mode = :any (
            @test_throws ErrorException try
                error("the failure the caller must see")
            finally
                PT.warn_on_failure(() -> error("a close that failed"), "close the video reader")
            end)
        @test err.value.msg == "the failure the caller must see"

        # The successful path is unchanged: the reader is left OPEN for the caller, which is what
        # `video` and the tests above rely on when they close `vid.vid` themselves.
        vid = PT.Video(base_file, 25, 25, 0, 2, 1.0)
        @test isopen(vid.vid)
        close(vid.vid)
        @test !isopen(vid.vid)
    end

    # #160: the writer is opened last and closed on every path out of the diagnostic — a
    # construction that fails after the open, a body that throws mid-export, and a finalization that
    # fails. None of them may leave a writer registered or a half-written file that a later reader
    # (the concatenation, or a user) would take for a complete diagnostic.
    @testset "a failed diagnostic export leaks no writer and leaves no file" begin
        # VideoIO's own registry: `open_video_out` adds to it and `close_video_out!` removes from
        # it (from inside its own `finally`, so a writer that failed to flush is still unregistered).
        # A delta of zero across a failed export is the direct evidence that nothing stayed open —
        # file existence alone would only show that the cleanup reached its last step. Read without
        # taking VideoIO's lock, which is sound only because everything below opens its writers on
        # this task: keep it that way, or take `VideoIO._active_writers_lock` too.
        nactive() = length(VideoIO._active_writers)
        # A frame the raw scene can resize, and a point inside it. Seeded: a failure must reproduce.
        frame = Gray{N0f8}.(rand(Xoshiro(20260910), N0f8, 80, 60))

        @testset "a successful export keeps its file and closes its writer" begin
            df = joinpath(DATADIR, "diag_ok.mp4")
            before = nactive()
            writer = Ref{VideoIO.VideoWriter}()
            PT.diagnose(df, false, nothing, 25.0) do dia
                writer[] = dia.writer
                PT.update_ratio!(dia, size(frame))
                dia(frame, (10, 10))
            end
            @test isfile(df)
            @test filesize(df) > 0
            @test isassigned(writer)        # the body ran at all, before anything is asked of it
            @test !isopen(writer[])
            @test nactive() == before
        end

        @testset "a failure in construction, after the open" begin
            df = joinpath(DATADIR, "diag_init.mp4")
            before = nactive()
            # The one fallible step left after the open is the construction itself: `radius` is an
            # `Int` field, and the constructor a parametric struct generates annotates its
            # arguments with the field types, so 1.5 does not even match it. What it stands for is
            # any step a later edit might add there — the writer is open by then, and only the
            # guard around it can close it. Before the fix this left the writer registered, and
            # VideoIO's `atexit` barrier timed out on it at the end of the session.
            err = @test_throws MethodError PT.Diagnostic(df, false, 25.0, PT.RawScene(); radius = 1.5, font = 20)
            # …and it is the ten-argument inner call that failed, not the four-argument one: a
            # `MethodError` raised BEFORE the open would satisfy every other assertion here for the
            # wrong reason, and go green on a constructor that leaks again.
            @test err.value.f === PT.Diagnostic
            @test length(err.value.args) == 10
            @test nactive() == before
            @test !isfile(df)
        end

        @testset "a failure while writing frames" begin
            df = joinpath(DATADIR, "diag_body.mp4")
            before = nactive()
            writer = Ref{VideoIO.VideoWriter}()
            err = @test_throws ErrorException PT.diagnose(df, false, nothing, 25.0) do dia
                writer[] = dia.writer
                PT.update_ratio!(dia, size(frame))
                dia(frame, (10, 10))            # a real frame first, so the file is genuinely partial
                error("injected frame-writing failure")
            end
            @test err.value.msg == "injected frame-writing failure"   # unchanged in type and message
            @test isassigned(writer)
            @test !isopen(writer[])
            @test nactive() == before
            @test !isfile(df)
        end

        @testset "a failure at finalization does not hide behind its own cleanup" begin
            df = joinpath(DATADIR, "diag_final.mp4")
            before = nactive()
            dia = PT.diagnose(df, false, nothing, 25.0)
            PT.update_ratio!(dia, size(frame))
            dia(frame, (10, 10))
            w = dia.writer
            # The load-bearing assertions here are the message and the missing file: the writer is
            # already closed by `CloseThenFail` itself, which is what makes the throw a FINALIZATION
            # failure rather than a fake one. The cleanup closes a second time and throws a second
            # time; the warning is where that goes, and the caller still gets the first exception.
            err = @test_logs (:warn,) match_mode = :any (
                @test_throws ErrorException PT.with_diagnostic(identity, CloseThenFail(dia), df))
            @test err.value.msg == "injected finalization failure"
            @test !isopen(w)
            @test nactive() == before
            @test !isfile(df)
        end

        @testset "a failing removal does not hide the exception either" begin
            # The other half of the cleanup, and the other way it could mask the failure: `file` is
            # a non-empty directory, so `rm(file; force = true)` throws on every platform — standing
            # in for the share's EACCES on an unlink, or a Windows handle still held. A `Dont` is
            # the diagnostic, so nothing but the removal can fail.
            undeletable = joinpath(DATADIR, "undeletable.mp4")
            mkpath(undeletable)
            touch(joinpath(undeletable, "occupant"))
            err = @test_logs (:warn,) match_mode = :any (
                @test_throws ErrorException PT.with_diagnostic(PT.Dont(), undeletable) do _
                    error("injected failure the removal must not replace")
                end)
            @test err.value.msg == "injected failure the removal must not replace"
        end

        @testset "no diagnostic requested: nothing to close, nothing to remove" begin
            before = nactive()
            @test PT.diagnose(dia -> dia isa PT.Dont, nothing, false, nothing, 25.0)
            err = @test_throws ErrorException PT.diagnose(nothing, false, nothing, 25.0) do _
                error("injected failure with no diagnostic")
            end
            @test err.value.msg == "injected failure with no diagnostic"
            @test nactive() == before
        end
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
