# The whole-run tracker (`track_whole_run`): the path on synthetic volumes built in memory, where
# every position is known exactly, then the whole pipeline on synthetic video — an AprilTag flight
# (the motion model), a plain one (no motion model), a run of two segments, and the clip.
#
# The online tracker's own suites are untouched by it; that it did not change is what the rest of the
# suite, run unchanged, says.
module WholeRunTests

using Test
using Fromage
using LinearAlgebra: norm
using Fromage.PawsomeTracker: ApriltagRectification, MotionModel, NoMotionModel, RunVolume,
    track_whole_run, whole_run_path, apply_h
using Random: Xoshiro
const PT = Fromage.PawsomeTracker
using ..Fixtures

# ---- in memory -------------------------------------------------------------------------------

# A frame of mid-grey ground under `hash_noise`, with dark discs of Gaussian profile (FWHM `width`)
# at each of `positions` (grid (row, col); `nothing` for one not in view).
function frame(positions, k; R, C, width, depth = 60)
    σ = width / 2sqrt(2log(2))
    return [
        begin
            v = 160 + Fixtures.hash_noise(r, c, k, 6)
            for p in positions
                isnothing(p) || (v -= depth * exp(-((r - p[1])^2 + (c - p[2])^2) / 2σ^2))
            end
            clamp(round(Int, v), 0, 255) % UInt8
        end for r in 1:R, c in 1:C
    ]
end

# A run of `n` samples, `dt` apart, one segment, every sample registered: `objects` are functions of
# the time `t` (s) giving a disc's grid position or `nothing`.
function volume(objects...; R = 60, C = 130, n, dt = 0.2, width = 2.0, start, anchor = 2.0)
    frames = [frame([o((k - 1) * dt) for o in objects], k; R, C, width) for k in 1:n]
    tss = [range(0.0; step = dt, length = n)]
    return RunVolume(frames, fill(true, n), PT.SMatrix{3, 3, Float64, 9}[], tss, start, anchor, width, dt)
end

# the worst distance, in grid px, between the path and where the object `o` is, over samples `ks`
worst(p, o, dt, ks = eachindex(p)) = maximum(k -> norm(collect(p[k]) .- collect(o((k - 1) * dt))), ks)

# The fitted walk's mean is 0.6 target widths per second; here a width is 2 grid px.
const WALK = 1.2

@testset "the whole-run tracker" begin
    @testset "a target walking at the fitted speed is followed, and an over-speed one refused" begin
        beetle = t -> (30.0, 10.0 + WALK * t)
        # 8 widths/s, crossing the beetle's path at t = 30 s: in view for ~3 s, and then parked a
        # few widths off it for good — a look-alike every second of the run after that
        crossing = t -> 26 <= t <= 32.4 ? (30.0 + 16 * (t - 30), 10.0 + WALK * 30) : t > 32.4 ? (50.0, 10.0 + WALK * 30) : nothing
        vol = volume(beetle, crossing; n = 300, start = (30.0, 10.0))
        p = whole_run_path(vol, MotionModel(missing), true)
        @test worst(p, beetle, vol.dt) < 1.0
        @test length(p) == 300
    end

    @testset "the arena prior ends the path at the arena's edge" begin
        # Two targets leave the start together in opposite directions, at walking speeds either side
        # of the fitted one, and stop together at t = 30 s: one 10 widths from the start, the other
        # 26. Where they end is what tells them apart, so the arena radius decides which one the run
        # is. Both stop together so neither sits still longer in the median background.
        near = t -> (30.0, 65.0 - 20 * min(t, 30.0) / 30)
        far = t -> (30.0, 65.0 + 52 * min(t, 30.0) / 30)
        vol = volume(near, far; n = 180, start = (30.0, 65.0))
        @test worst(whole_run_path(vol, MotionModel(10.0), true), near, vol.dt) < 1.5
        @test worst(whole_run_path(vol, MotionModel(26.0), true), far, vol.dt) < 1.5
    end

    @testset "without the motion model, a moving target is followed sample by sample" begin
        # about one width per second, the step σ the variant assumes
        target = t -> (30.0 + 4 * sin(t / 2), 20.0 + 2 * t)
        vol = volume(target; n = 200, start = (30.0, 20.0))
        @test worst(whole_run_path(vol, NoMotionModel(), true), target, vol.dt) < 1.0
    end

    @testset "unregistered first samples do not erase the target's contrast (#406)" begin
        # An unregistered sample scores 0 everywhere. With most of the first second unregistered, a
        # median over every sample of it made the target's own contrast 0, every dark object then
        # scored below bare ground, and the path wandered off the target for the whole run.
        # Held on the registered samples only: an unregistered one has nothing to place it by.
        # Three of the first second's five, and then all five (the first registered sample stands in).
        beetle = t -> (30.0, 20.0 + WALK * t)
        vol = volume(beetle; n = 100, start = (30.0, 20.0))
        @testset "first $lost samples unregistered" for lost in (3, 5)
            registered = [k > lost for k in eachindex(vol.frames)]
            late = RunVolume(vol.frames, registered, vol.Hinvs, vol.tss, vol.start, vol.anchor, vol.width, vol.dt)
            @test worst(whole_run_path(late, MotionModel(missing), true), beetle, vol.dt, findall(registered)) < 1.0
        end
    end

    @testset "large foreground: big regions that differ from the background, dilated, on the footprint" begin
        R, C = 40, 60
        frames = [fill(0x80, R, C)]
        vol = RunVolume(frames, [true], PT.SMatrix{3, 3, Float64, 9}[], [0.0:0.2:0.0], (20.0, 10.0), 2.0, 2.0, 0.2)
        bg = fill(128.0f0, R, C)
        f = frames[1]
        f[11:20, 11:20] .= 0x80 - 0x14   # 100 px, 25 widths², exactly FG_GREY darker: large
        f[30:33, 40:43] .= 0x10          # 16 px, much darker: a target, not large
        f[1:12, 46:60] .= 0xff           # 180 px brighter …
        f[1:12, 55:60] .= 0x00           # … of which 108 are on the footprint: large
        L = only(PT.large_foreground(vol, bg))
        @test all(L[9:22, 9:22])                                 # dilated by a width, 2 px
        @test !L[8, 15] && !L[23, 15] && !L[15, 8] && !L[15, 23]
        @test !any(L[28:35, 38:45])
        @test all(L[1:14, 44:56]) && !any(L[:, 57:60])           # the footprint's part, dilated
        f[20, 11:20] .= 0x80                                     # 90 px, under 25 widths²: not large
        f[1, 46:54] .= 0x80                                      # 99 px: not large
        @test !any(only(PT.large_foreground(vol, bg)))
    end

    @testset "a large dark body passing the target does not take the path (#412)" begin
        # A target that fades after the first second, and a body as dark as the target was (a person,
        # or their shadow, 16 px across: 50 widths²) walking the other way along the target's path, 6
        # px beside it, then parked. Its rim scores like the target, and without large foreground
        # the path leaves with it; with it, the path stays on the target.
        beetle = t -> (30.0, 20.0 + WALK * t)
        body = t -> (16.0, max(12.0, 20.0 + WALK * 30 - 3 * (t - 30)))
        R, C, n, dt = 60, 130, 300, 0.2
        frames = map(1:n) do k
            t = (k - 1) * dt
            f = frame([beetle(t)], k; R, C, width = 2.0, depth = t < 2 ? 60 : 40)
            p = body(t)
            for c in 1:C, r in 1:R
                (r - p[1])^2 + (c - p[2])^2 <= 64 && (f[r, c] = max(0, Int(f[r, c]) - 60))
            end
            f
        end
        vol = RunVolume(frames, fill(true, n), PT.SMatrix{3, 3, Float64, 9}[], [range(0.0; step = dt, length = n)], (30.0, 20.0), 2.0, 2.0, dt)
        bg = PT.background(vol.frames)
        z = PT.score_dark(vol, bg, true)
        none = [falses(R, C) for _ in 1:n]   # no large foreground anywhere: the tracker before #412
        @testset "$(nameof(typeof(model)))" for model in (MotionModel(missing), NoMotionModel())
            @test worst(PT.whole_run_path!(copy(z), none, vol, model), beetle, dt) > 20
            @test worst(whole_run_path(vol, model, true), beetle, dt) < 1.0
        end
    end

    @testset "a lighter target" begin
        vol = volume(t -> (30.0, 20.0 + WALK * t); n = 50, start = (30.0, 20.0))
        inverted = RunVolume([0xff .- f for f in vol.frames], vol.has, vol.Hinvs, vol.tss, vol.start, vol.anchor, vol.width, vol.dt)
        @test worst(whole_run_path(inverted, MotionModel(missing), false), t -> (30.0, 20.0 + WALK * t), vol.dt) < 1.0
    end

    # ---- the review (#418) ----------------------------------------------------------------------

    # A whole-run row's tuning for an in-memory volume, whose grid is the full resolution: a target
    # width of 2 px at downscale 1, as `volume` draws it.
    review_tuning(video_type = missing) = PT.Tuning(2.0, 21, true, 5.0, 25.0, 4.0, 1.0, 250, 1 // 1, true, missing, video_type)

    @testset "the fastest second of a track, and where it starts" begin
        track = [(0.0, 1.0 * (k - 1)) for k in 1:11]   # 5 px/s at 5 samples/s …
        track[6] = (0.0, 12.0)                          # … but 12 px over the first second
        @test PT.fastest_second(track, 2.0, 0.2) == (6.0, 1)   # in widths of 2 px
        @test isequal(PT.fastest_second(track[1:3], 2.0, 0.2), (0.0, missing))   # under a second
    end

    @testset "the longest stretch two tracks are apart, and where it starts" begin
        a = [(0.0, 0.0) for _ in 1:12]
        b = copy(a)
        b[4:8] .= Ref((0.0, 6.1))     # more than 3 widths of 2 px …
        b[11:12] .= Ref((7.0, 0.0))
        b[2] = (6.0, 0.0)             # … and exactly 3, which is not more
        @test PT.stretch(a, b, 2.0, 0.2) == (1.0, 4)
        @test isequal(PT.stretch(a, a, 2.0, 0.2), (0.0, missing))
    end

    @testset "a moment is placed on the run clock and in its segment's file" begin
        tss = [range(3.0; step = 0.2, length = 5), range(10.0; step = 0.2, length = 3)]
        @test PT.Moment(tss, 1) == PT.Moment(3.0, 1, 3.0)
        @test PT.Moment(tss, 5).segment == 1
        m = PT.Moment(tss, 7)                  # the second segment's second sample
        @test (m.segment, m.file_time) == (2, 10.2)
        @test m.run_time ≈ 4.2                     # the run clock closes up the gap between segments
    end

    @testset "the margin cut is the video type's, and a blank one falls back by footage" begin
        @test PT.margin_cut("indoor infrared", PT.NoMotionModel()) == 108.72479f0
        @test PT.margin_cut("drone", PT.NoMotionModel()) == PT.margin_cut(missing, MotionModel(missing))
        @test PT.margin_cut(missing, NoMotionModel()) == PT.POOLED_MARGIN_CUT
        @test_throws ArgumentError PT.margin_cut("drones", NoMotionModel())
        @test PT.margin_cut("tripod outdoor sand mirror", MotionModel(missing)) == PT.POOLED_MARGIN_CUT
        @test Set(PT.VIDEO_TYPES) == Set(
            [
                "drone", "tripod outdoor plywood", "static outdoor sand mirror",
                "tripod outdoor sand mirror", "indoor LED", "indoor infrared",
            ]
        )
    end

    @testset "the margin's backward steps are their forward steps reversed, entry cost included" begin
        # Pointwise against the definition, on random scores and a random large foreground: out[x]
        # is the best move from x, less the no-return cost (walking) and the entry cost of a long
        # move from outside the mask into it — the costs the forward steps pay on the same move.
        rng = Xoshiro(418)
        R, C, width, ec = 15, 17, 2.0, 2.5f0
        src = randn(rng, Float32, R, C)
        fgK = BitMatrix(rand(rng, R, C) .< 0.3)
        rmap = Float32[hypot(r - 8, c - 9) / 0.5 for r in 1:R, c in 1:C]   # past RETURN_FREE in places
        function definition(cost_of, offsets, long)
            return [
                maximum(
                    j -> begin
                        rr, cc = r + offsets[j][1], c + offsets[j][2]
                        (1 <= rr <= R && 1 <= cc <= C) || return -Inf32
                        s = src[rr, cc] - cost_of(j, r, c, rr, cc)
                        !fgK[r, c] && long[j] && fgK[rr, cc] ? s - ec : s
                    end, eachindex(offsets)
                ) for r in 1:R, c in 1:C
            ]
        end
        for ((offsets, logp), rc) in zip(PT.step_kernels(width), (0.0f0, Float32(PT.RETURN_COST)))
            long = PT.long_moves(offsets, width)
            out = PT.backward_pass!(similar(src), src, (offsets, logp), rmap, rc, fgK, long, ec)
            back(j, r, c, rr, cc) = -logp[j] + (rc > 0 && rmap[r, c] > PT.RETURN_FREE && rmap[r, c] > rmap[rr, cc] ? rc * (rmap[r, c] - rmap[rr, cc]) : 0.0f0)
            @test out ≈ definition(back, offsets, long)
        end
        offsets = [(dr, dc) for dc in -2:2 for dr in -2:2 if dr^2 + dc^2 <= 4]
        cost = Float32[(dr^2 + dc^2) / 2 for (dr, dc) in offsets]
        long = PT.long_moves(offsets, width)
        out = PT.no_motion_backward!(similar(src), src, offsets, cost, fgK, long, ec)
        @test out ≈ definition((j, _...) -> cost[j], offsets, long)
    end

    @testset "the path holds the max-marginal at every step" begin
        # The backward pass completes the forward messages into max-marginals; the best path's point
        # is their maximum at every step (to Float32 rounding), here with a body in large foreground.
        beetle = t -> (30.0, 20.0 + WALK * t)
        body = t -> (16.0, max(12.0, 20.0 + WALK * 30 - 3 * (t - 30)))
        vol = volume(beetle; n = 200, start = (30.0, 20.0))
        frames = map(enumerate(vol.frames)) do (k, f)
            p = body((k - 1) * vol.dt)
            [(r - p[1])^2 + (c - p[2])^2 <= 64 ? UInt8(max(0, Int(f[r, c]) - 60)) : f[r, c] for r in axes(f, 1), c in axes(f, 2)]
        end
        vol = RunVolume(frames, vol.has, vol.Hinvs, vol.tss, vol.start, vol.anchor, vol.width, vol.dt)
        bg = PT.background(vol.frames)
        fg = PT.large_foreground(vol, bg)
        @test any(any, fg)
        @testset "$(nameof(typeof(model)))" for model in (MotionModel(missing), NoMotionModel())
            z = PT.score_dark(vol, bg, true)
            za = PT.anchor_contrast(z, vol)
            PT.penalise_large_blobs!(z, fg, za, vol.width)
            F = PT.forward_store(model, z, vol)
            nodes, margin = PT.best_path(model, z, za, vol, fg, F)
            M = F isa Tuple ? first(F) : F
            gap(K) = maximum(view(M, :, :, K)) - M[round(Int, nodes[K][1]), round(Int, nodes[K][2]), K]
            @test maximum(gap, eachindex(nodes)) < 1.0e-4
            @test length(margin) == length(nodes) && all(≥(0), margin)
            # the same path as without the margin's store
            @test first(PT.best_path(model, z, za, vol, fg, nothing)) == nodes
        end
    end

    # The signal scenes below solve only what each signal needs (a path, or a path and its margin);
    # a whole review is two more solves, and these tests run under coverage in CI.
    path_and_margin(vol, model) = PT.solve(vol, model, true, eachindex(vol.frames), PT.WithMargin())

    @testset "ambiguous: two look-alikes leaving the start together leave little margin" begin
        lone = volume(t -> (30.0, 20.0 + WALK * t); n = 150, start = (30.0, 20.0))
        twins = volume(t -> (30.0 - 0.6t, 40.0 + WALK * t), t -> (30.0 + 0.6t, 40.0 + WALK * t); n = 150, start = (30.0, 40.0))
        @testset "$(nameof(typeof(model)))" for model in (MotionModel(missing), NoMotionModel())
            _, a = path_and_margin(lone, model)
            _, b = path_and_margin(twins, model)
            # measured 27.7 against 0.95 with the motion model, 76.8 against 7.2 without
            @test minimum(b) < minimum(a) / 5
            s = PT.ambiguous_signal(a, lone, model, review_tuning())
            @test s.value == minimum(a)
            @test s.cut == PT.margin_cut(missing, model) && !s.flagged
            # a video type's cut, high enough to flag the lone target
            s = PT.ambiguous_signal(a, lone, model, review_tuning("indoor infrared"))
            @test s.cut == PT.margin_cut("indoor infrared", model) && s.flagged
            @test s.moment isa PT.Moment
        end
    end

    @testset "unstable: a target in the first half's background loses the path to a look-alike" begin
        # The target sits at the start for 65 s of a 150 s run, so the median of the first half holds
        # it and the median of the whole run does not; a look-alike walks off from beside it over
        # those 65 s, and is gone. On the first half's background the path follows the look-alike.
        # At 2 samples/s, and without the motion model only: the signal is the same code under
        # either, and the AprilTag flight below reviews a motion-model run.
        still = 65.0
        target = t -> t < still ? (30.0, 40.0) : (30.0, 40.0 + WALK * (t - still))
        decoy = t -> t < still ? (30.0 + 0.4 * t, 42.0 + 0.5 * t) : nothing
        vol = volume(target, decoy; R = 64, C = 150, n = 300, dt = 0.5, start = (30.0, 40.0))
        p, review = PT.whole_run_review(vol, NoMotionModel(), review_tuning())
        @test worst(p, target, vol.dt) < 4.0                       # the path itself holds: 2 widths (measured 3.4)
        s = review.unstable
        @test s.cut == PT.UNSTABLE_SECONDS
        @test PT.UNSTABLE_SECONDS <= s.value < still               # measured 63
        @test s.flagged && PT.flagged(review)
        @test 0 < s.moment.run_time < 10                           # measured 7
        @test !review.fast.flagged
    end

    @testset "fast: held to SUSPECT_SPEED on AprilTag footage only" begin
        # The target vanishes at 10 s, and a look-alike leaves its last place at 8 widths/s and parks:
        # both paths take it (measured 7.5 widths/s without the motion model, 5.7 with), and only
        # the motion model's is held to the cut.
        beetle = t -> t < 10 ? (30.0, 20.0 + WALK * t) : nothing
        leap = t -> t < 10 ? nothing : (30.0 + 16 * min(t - 10, 1.0), 20.0 + WALK * 10)
        vol = volume(beetle, leap; n = 100, start = (30.0, 20.0))
        fast(model) = PT.fast_signal(PT.full_track(whole_run_path(vol, model, true), 1.0), vol, model, review_tuning())
        plain = fast(NoMotionModel())
        @test plain.value > PT.SUSPECT_SPEED
        @test ismissing(plain.cut) && !plain.flagged
        @test 9 < plain.moment.run_time < 11
        drone = fast(MotionModel(missing))
        @test drone.cut == PT.SUSPECT_SPEED
        @test drone.value > PT.SUSPECT_SPEED && drone.flagged
        @test 9 < drone.moment.run_time < 11
    end

    @testset "review/flags.csv: a row per whole-run run and signal, and a warning per flagged run" begin
        S(v, cut, f, m = missing) = PT.Signal{typeof(v)}(v, cut, f, m)
        quiet = PT.Review(S(1.2, missing, false, PT.Moment(4.2, 2, 3661.25)), S(30.5f0, 2.87998f0, false, PT.Moment(0.0, 1, 0.0)), S(0.0, 60.0, false))
        loud = PT.Review(S(4.04, 3.0, true, PT.Moment(1.0, 1, 1.0)), S(0.5f0, 1.0039139f0, true, PT.Moment(2.0, 1, 2.0)), S(61.0, 60.0, true, PT.Moment(3.0, 1, 3.0)))
        run(id, whole) = (; run_id = id, tuning = (; whole_run = whole))
        tracked(review...) = (; track = (0.0:0.2:1.0, [], [], review...))
        dir = mktempdir()
        file = joinpath(dir, "review", "flags.csv")
        rs = [run("quiet, as can be", true), run("online", false), run("loud", true)]
        runs = [tracked(quiet), tracked(), tracked(loud)]
        @test_logs (:warn, r"^run loud: its whole-run track is flagged for review: its fastest second covers 4\.0 target widths, more than the 3\.0 a walk does; its anchored margin falls to 0\.5, under its video type's cut of 1\.0; it moves for 61\.0 s when its background is built from half the run\. .*review.flags\.csv$") Fromage.write_review(dir, rs, runs)
        header, lines... = readlines(file)
        @test header == "run_id,signal,value,cut,flagged,time,segment,file_time"
        @test lines[1:3] == [
            "\"quiet, as can be\",fast,1.2,,false,4.2,2,01:01:01.250",
            "\"quiet, as can be\",ambiguous,30.5,2.87998,false,0.0,1,00:00:00.000",
            "\"quiet, as can be\",unstable,0.0,60.0,false,,,",
        ]
        @test length(lines) == 6 && all(startswith("loud,"), lines[4:6])   # online runs get no rows
        # no whole-run run, no file
        rm(file)
        Fromage.write_review(dir, rs[2:2], runs[2:2])
        @test !isfile(file)
    end

    # ---- through video ---------------------------------------------------------------------------

    dir = mktempdir()

    @testset "an AprilTag flight: the motion model, past an over-speed distractor" begin
        # 12 px disc, 10 s at 25 fps: 72 ground px is 0.6 widths/s, the fitted walk. The distractor
        # crosses its path at 8 widths/s around t = 5 s and parks 7 widths away.
        cross(k) = 100 <= k <= 150 ? (280 + 96 * (k - 125) / 25 / sqrt(2), 290 - 96 * (k - 125) / 25 / sqrt(2)) :
            k > 150 ? (280 + 96 / sqrt(2), 290 - 96 / sqrt(2)) : nothing
        # Frames 51–55 lose a tag: the sample at 2 s (frame 51) has no registration of its own (#401).
        v = make_apriltag_video(dir, "whole"; nframes = 250, tw = 12, textured = true, distractor = cross, noise = 4, occlude = 51:55)
        rect = ApriltagRectification(;
            aspect = 1.0, file = joinpath(dir, v.file), extrinsic = 0, ntags = 4, family = "tag36h11",
            tag_cell_width = Fixtures.TAG_CELL, center = missing, north = missing, width = 480, height = 480
        )
        segs = segments(joinpath(dir, v.file); start_location = v.start_location)
        t = tuning(segs[1].file; target_width = 12, whole_run = true, downscale = 1 / 3, sample_fps = 5)
        clip = joinpath(dir, "whole_clip.mp4")   # not the flight's own name, which it would overwrite
        ts, coords, px, review = track_whole_run(segs, t, rect, clip)
        @test length(ts) == 50 && step(ts) ≈ 0.2
        @test review isa PT.Review
        # the prediction, carried through the pipeline's own maps as test/apriltag_pipeline.jl does
        expected = [rect.image2real(apply_h(rect.reference.M, v.expected_ref(round(Int, s * 25) + 1))) for s in ts]
        errors = [norm(c - e) for (c, e) in zip(coords, expected) if !ismissing(c)]
        @test length(errors) == 50         # the unregistered sample too: it has a position
        # ground px; a grid px is 3. The unregistered sample scores 0 everywhere, so `refine` places
        # it anywhere within a target width of its path point (measured 8.1, the rest ≤ 2.3): it is
        # held to that instead.
        @test maximum(errors[setdiff(1:50, 11)]) < 3
        @test errors[11] < 12
        # Its display pixels are in the RAW frame, each through its own sample's registration, so
        # they follow the drone's pan (`image_xy`), not the reference (`expected_ref`). The one
        # sample with no registration has none (#401).
        unregistered = findall(s -> 51 <= round(Int, s * 25) + 1 <= 55, ts)
        @test unregistered == [11]
        @test findall(ismissing, px) == unregistered
        @test !ismissing(coords[11])
        raw_errors = [norm(px[k] - v.image_xy(round(Int, s * 25) + 1)) for (k, s) in enumerate(ts) if !ismissing(px[k])]
        @test maximum(raw_errors) < 3      # raw px: the pan is a pure translation, so a grid px is 3
        ref_errors = [norm(px[k] - v.expected_ref(round(Int, s * 25) + 1)) for (k, s) in enumerate(ts) if !ismissing(px[k])]
        @test maximum(ref_errors) > 10     # the pan, which reference-space pixels would not show
        # two windows of the same flight: one run, one path, each segment finding its tags and
        # registering on its own, and only the first one's start location read
        halves = segments(fill(joinpath(dir, v.file), 2); start = [0.0, 5.0], stop = [5.0, 10.0], start_location = [v.start_location, missing])
        _, halves_coords = track_whole_run(halves, t, rect, nothing)
        @test length(halves_coords) == 50
        @test maximum(norm(halves_coords[k] - expected[k]) for k in setdiff(1:50, 11)) < 3
        # the clip: the AprilTag scene's square canvas, every sample written at 5 Hz
        s = probe_stream(clip)
        @test (s.width, s.height) == (PT.DIAGNOSTIC_SIZE, PT.DIAGNOSTIC_SIZE)
        @test s.nframes == 50

        # and through `main`, from a runs.csv that opts in: the same track, in the csv
        open(joinpath(dir, "rectifications.csv"), "w") do io
            println(io, "rectification_id,type,file,extrinsic,apriltags,family,tag_cell_width")
            println(io, "drone,apriltag,$(v.file),0,4,tag36h11,8")
        end
        open(joinpath(dir, "runs.csv"), "w") do io
            println(io, "run_id,rectification_id,file,start_location,target_width,whole_run,video_type")
            println(io, "beetle,drone,$(v.file),\"$(v.start_location)\",12,true,")
        end
        results_dir = mktempdir()
        main(dir; results_dir)
        header, lines... = readlines(joinpath(results_dir, "beetle.csv"))
        @test header == "time,x,y,x_display,y_display"
        cells = split.(lines, ',')
        @test [parse(Float64, c[1]) for c in cells] ≈ collect(ts)
        @test [PT.SVector(parse(Float64, c[3]), parse(Float64, c[2])) for c in cells] ≈ coords
        # the unregistered sample keeps its real-world position and leaves its pixel cells empty
        @test isempty(cells[11][4]) && isempty(cells[11][5]) && !isempty(cells[11][2])
        @test all(k -> k == 11 || PT.SVector(parse(Float64, cells[k][4]), parse(Float64, cells[k][5])) ≈ px[k], eachindex(cells))
        @test isfile(joinpath(results_dir, "diagnostic.mp4"))
        # the review: three rows, its values the tracker's own, and a blank video type held to the
        # drone cut on AprilTag footage (that online runs get none, `write_review`'s own test says)
        header, lines... = readlines(joinpath(results_dir, "review", "flags.csv"))
        @test header == "run_id,signal,value,cut,flagged,time,segment,file_time"
        cells = split.(lines, ',')
        @test [c[1:2] for c in cells] == [["beetle", "fast"], ["beetle", "ambiguous"], ["beetle", "unstable"]]
        @test [parse(Float64, c[3]) for c in cells] ≈ [review.fast.value, review.ambiguous.value, review.unstable.value]
        @test cells[1][4] == "3.0" && cells[3][4] == "60.0"
        @test parse(Float32, cells[2][4]) == PT.margin_cut("drone", nothing)
        @test all(c -> isempty(c[6]) || occursin(r"^\d\d:\d\d:\d\d\.\d{3}$", c[8]), cells)
    end

    @testset "a plain video: no motion model, stored pixels out" begin
        files, expected = make_target_video(dir, "plainwr"; width = 100, height = 100, target_width = 20, duration = 4, noise = 10)
        file = joinpath(dir, only(files))
        segs = segments(file; start_location = (55, 50))
        t = tuning(file; target_width = 20, whole_run = true, downscale = 1 / 3, sample_fps = 5)
        ts, ij, px = track_whole_run(segs, t, nothing, joinpath(dir, "plainwr_dia.mp4"))
        @test length(ts) == 20
        # `expected` is 1-based (row, col); `track` reports 0-based stored pixels
        @test maximum(k -> norm(collect(ij[k]) .- (collect(expected(k; skip = 5)) .- 1)), eachindex(ij)) < 3    # one grid px
        # and display (x, y) pixels, the same samples swapped (sar 1), never `missing` (#401)
        @test eltype(px) == PT.SVector{2, Float64}
        @test maximum(k -> norm(collect(px[k]) .- reverse(collect(expected(k; skip = 5)) .- 1)), eachindex(px)) < 3
        @test all(k -> collect(px[k]) ≈ reverse(collect(ij[k])), eachindex(px))
        s = probe_stream(joinpath(dir, "plainwr_dia.mp4"))
        @test s.nframes == 20
    end

    @testset "an anamorphic video: display pixels are stretched back by sar (#401)" begin
        files, expected = make_target_video(dir, "sarwr"; width = 100, height = 100, sar = 2 // 1, target_width = 20, duration = 4, noise = 10)
        file = joinpath(dir, only(files))
        t = tuning(file; target_width = 20, whole_run = true, downscale = 1 / 3, sample_fps = 5)
        @test t.aspect == 2
        _, ij, px = track_whole_run(segments(file; start_location = (55, 50)), t, nothing, nothing)
        # `expected` is the stored (row, col); display is (col × sar, row)
        truth(k) = ((r, c) = expected(k; skip = 5); [2c, r])
        # One and a half grid px: the path's own stored-column misses reach 1.97 at the sine's turns
        # (measured worst 3.94 display px), and a stored column is sar display columns.
        @test maximum(k -> norm(collect(px[k]) .- truth(k)), eachindex(px)) < 4.5
        @test all(k -> collect(ij[k]) ≈ [px[k][2], px[k][1] / 2], eachindex(px))
        # Through a real rectification the pixels do not change, and each one, taken back through
        # `to_stored` and the rectification, is its own sample's real-world position: the csv's
        # round trip, on the whole-run tracker.
        rect = Fromage.Rectifications.from_uniform(;
            pixel_width = 0.5, aspect = 2.0, center = missing, north = missing, width = 50, height = 100
        )
        _, xy, rpx = track_whole_run(segments(file; start_location = (55, 50)), t, rect, nothing)
        @test rpx == px
        @test all(k -> rect.image2real(PT.SVector(Fromage.Spaces.to_stored(rpx[k], 2)...)) ≈ xy[k], eachindex(xy))
    end

    @testset "a run of two segments is one path" begin
        files, expected = make_target_video(dir, "twowr"; width = 100, height = 100, target_width = 20, duration = 4, nsegments = 2, noise = 10)
        paths = joinpath.(dir, files)
        segs = segments(paths; start_location = [(55, 50), missing])
        t = tuning(first(paths); target_width = 20, whole_run = true, downscale = 1 / 3, sample_fps = 5, duration = 4)
        ts, ij = track_whole_run(segs, t, nothing, nothing)
        @test length(ts) == 20 && first(ts) == 0.0     # one clock, as the online tracker's
        @test maximum(k -> norm(collect(ij[k]) .- (collect(expected(k; skip = 5)) .- 1)), eachindex(ij)) < 3    # one grid px
    end

    @testset "where a path is anchored, by how its start is given (#397)" begin
        # A searched-for start, around a pixel or (AprilTag mode's `missing`) the grid's centre, is
        # anchored within the initial search's radius, min(R, C) / 2initial_search_factor; a given
        # start within half a tracking window, whatever the factor.
        t = PT.Tuning(10.0, 21, true, 5.0, 25.0, 4.0, 1 / 3, 250, 1 // 1, true, missing, missing)
        to_grid((x, y)) = (y + 1.0, x + 1.0)
        @test PT.anchor(missing, to_grid, t, (60, 90)) == ((30.5, 45.5), 60 / 8)
        @test PT.anchor(PT.StartSearch((20, 10)), to_grid, t, (60, 90)) == ((11.0, 21.0), 60 / 8)
        @test PT.anchor((20, 10), to_grid, t, (60, 90)) == ((11.0, 21.0), t.downscale * 21 / 2)
    end
end

end
