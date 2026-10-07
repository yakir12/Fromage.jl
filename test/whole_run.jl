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
    fastest_second, track_whole_run, whole_run_path, apply_h
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

# the worst distance, in grid px, between the path and where the object `o` is
worst(p, o, dt) = maximum(k -> norm(collect(p[k]) .- collect(o((k - 1) * dt))), eachindex(p))

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
        beetle = t -> (30.0, 20.0 + WALK * t)
        vol = volume(beetle; n = 100, start = (30.0, 20.0))
        late = RunVolume(vol.frames, [k > 3 for k in 1:100], vol.Hinvs, vol.tss, vol.start, vol.anchor, vol.width, vol.dt)
        @test worst(whole_run_path(late, MotionModel(missing), true), beetle, vol.dt) < 1.0
    end

    @testset "a lighter target" begin
        vol = volume(t -> (30.0, 20.0 + WALK * t); n = 50, start = (30.0, 20.0))
        inverted = RunVolume([0xff .- f for f in vol.frames], vol.has, vol.Hinvs, vol.tss, vol.start, vol.anchor, vol.width, vol.dt)
        @test worst(whole_run_path(inverted, MotionModel(missing), false), t -> (30.0, 20.0 + WALK * t), vol.dt) < 1.0
    end

    @testset "the fastest second of a track" begin
        ts = range(0.0; step = 0.2, length = 11)
        coords = [PT.SVector(0.0, 1.0 * (k - 1)) for k in 1:11]   # 5 units/s
        coords[6] = PT.SVector(0.0, 12.0)                          # one jump: 12 units in the first second …
        @test fastest_second(ts, coords) ≈ 12.0
        missings = Vector{Union{Missing, PT.SVector{2, Float64}}}(coords)
        missings[6] = missing                                        # … which a missing sample hides
        @test fastest_second(ts, missings) ≈ 5.0
        @test fastest_second(range(0.0; step = 0.2, length = 3), coords[1:3]) == 0.0   # under a second
    end

    @testset "a whole-run track whose fastest second is too fast is flagged" begin
        # target width 2, one real unit per pixel: a width is 2 units
        ts = range(0.0; step = 0.2, length = 11)
        slow = [PT.SVector(0.0, 0.2 * (k - 1)) for k in 1:11]         # 0.5 widths/s
        fast = copy(slow)
        fast[6] = PT.SVector(0.0, 8.0)                                  # 8 units in a second: 4 widths/s
        @test_logs (:warn, r"run r: .*fastest second.*4\.0 target widths") Fromage.warn_if_fast("r", 2.0, (ts, fast), 1.0)
        @test_logs Fromage.warn_if_fast("r", 2.0, (ts, slow), 1.0)
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
        ts, coords, px = track_whole_run(segs, t, rect, clip)
        @test length(ts) == 50 && step(ts) ≈ 0.2
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
            println(io, "run_id,rectification_id,file,start_location,target_width,whole_run")
            println(io, "beetle,drone,$(v.file),\"$(v.start_location)\",12,true")
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
        t = PT.Tuning(10.0, 21, true, 5.0, 25.0, 4.0, 1 / 3, 250, 1 // 1, true, missing)
        to_grid((x, y)) = (y + 1.0, x + 1.0)
        @test PT.anchor(missing, to_grid, t, (60, 90)) == ((30.5, 45.5), 60 / 8)
        @test PT.anchor(PT.StartSearch((20, 10)), to_grid, t, (60, 90)) == ((11.0, 21.0), 60 / 8)
        @test PT.anchor((20, 10), to_grid, t, (60, 90)) == ((11.0, 21.0), t.downscale * 21 / 2)
    end
end

end
