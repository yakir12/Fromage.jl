# Stage-by-stage coverage of the AprilTag detection pipeline over a synthetic drone flight whose
# ground truth is analytic (see `make_apriltag_video` in test/fixtures.jl). Where test/apriltag.jl
# unit-tests the ground-plane geometry with no detector and no video, this drives the WHOLE path —
# render, encode, detect, register, track, rectify — and asserts every frame against a position
# known in closed form.
#
# The invariant everything here is built on: the disc's position in the REFERENCE frame is
# `pose_apply(H_1, ground_xy(k))`, independent of the drone pose `H_k`, because cancelling `H_k` is
# exactly what registration is for. So one prediction serves every flight, and only the flight
# changes between testsets.
#
# Why the guess tests matter (stage 5a): `track_apriltag` never corrects its guess explicitly. The
# guess lives in reference-space coordinates and drone motion is removed lazily, inside
# `RegisteredWarp`, so "the next guess is simply the last position" is correct ONLY while the
# per-frame homography registration is right. If auto-registration broke, the guess would fall
# outside the DoG search window and the track would diverge — so the registration assertions below
# are the direct test of it.
module ApriltagPipelineTests

using Test
using Fromage
using StaticArrays: SVector
using LinearAlgebra: norm
using AprilTags: AprilTagDetector, freeDetector!, tag36h11
using Fromage.PawsomeTracker: ApriltagRectification, track, detect_tags, register, set_detector!,
    apply_h
using ..Fixtures

const NFRAMES = 40
const TARGET_WIDTH = 12
const WINDOW = 2TARGET_WIDTH          # the DoG search window `track` derives from target_width
const FRAME = 480                     # the fixture's frame is FRAME x FRAME
const CENTRE = FRAME ÷ 2

# Tolerances, in the fixture's metric unit — which `tag_cell_width = TAG_CELL` makes exactly one
# ground pixel. Measured worst cases over every flight below are ~0.37 (registration) and ~0.44
# (track), so these sit at roughly 3x headroom: loose enough to survive detector and encoder
# jitter, far tighter than any real breakage, which misplaces things by tens of pixels.
const REG_TOL = 1.0
const TRACK_TOL = 1.5

"Build the rectification the runs CSV would build, from frame 1 as the extrinsic frame."
rectify(file) = ApriltagRectification(; aspect = 1.0, file, extrinsic = 0, ntags = 4, family = "tag36h11",
                                        tag_cell_width = Fixtures.TAG_CELL, center = missing,
                                        north = missing, width = FRAME, height = FRAME)

# Detect and register every frame directly, with no tracker involved, and report where each frame
# says the disc is in REFERENCE coordinates. Frames are re-rendered in memory rather than decoded,
# so this isolates detection + registration from the video layer entirely.
function registration_trace(v, ref)
    ground = apriltag_ground()
    det = set_detector!(AprilTagDetector(tag36h11))
    ids = [0, 1, 2, 3]
    try
        map(1:NFRAMES) do k
            img = render_pose(Fixtures.draw_disc(ground, v.groundpath[k]..., TARGET_WIDTH),
                              v.poses[k], FRAME, FRAME)
            tc = detect_tags(det, img, ids)
            isnothing(tc) && return nothing
            apply_h(register(ref, reduce(vcat, tc)), v.image_xy(k))
        end
    finally
        freeDetector!(det)
    end
end

"""
Run one flight end to end and assert the two contracts that define a working pipeline:

  * **registration** — every frame's fitted homography maps the disc's true image position back
    onto its fixed reference position, and the resulting frame-to-frame step stays well inside the
    DoG search window (which is what makes the un-corrected guess correct);
  * **track** — the coordinates `track` reports match, frame by frame, the intended ground path
    carried through the pipeline's own declared maps (`ref.M`, then `image2real`). Both are fixed
    properties of the reference frame rather than of the track, so the prediction stays independent
    of the thing it is checking.
"""
function check_flight(dir, name, pose; teeth = false)
    v = make_apriltag_video(dir, name; nframes = NFRAMES, tw = TARGET_WIDTH, pose)
    file = joinpath(dir, v.file)
    rect = rectify(file)

    # ---- registration (stage 5a) -------------------------------------------------------------
    refpos = registration_trace(v, rect.reference)
    @test !any(isnothing, refpos)                       # every frame held all four tags
    @test maximum(norm(refpos[k] - v.expected_ref(k)) for k in 1:NFRAMES) < REG_TOL
    # the guess is never corrected, so the target must not move far in reference space
    steps = [norm(refpos[k+1] - refpos[k]) for k in 1:NFRAMES-1]
    @test maximum(steps) < WINDOW / 2
    if teeth
        # ...and that is a real achievement, not a tautology: in raw image space the same target
        # moves further than a whole search window between frames, so a tracker that skipped
        # registration would lose it immediately.
        raw = [norm(v.image_xy(k+1) - v.image_xy(k)) for k in 1:NFRAMES-1]
        @test maximum(raw) > WINDOW
    end

    # ---- the track (stage 5b) ----------------------------------------------------------------
    _, xy = track1(file; rectification = rect, start_location = v.start_location,
                   target_width = TARGET_WIDTH)
    @test length(xy) == NFRAMES
    @test !any(ismissing, xy)
    expected(k) = rect.image2real(apply_h(rect.reference.M, v.expected_ref(k)))
    @test maximum(norm(xy[k] - expected(k)) for k in 1:NFRAMES) < TRACK_TOL
    return (; v, rect, refpos)
end

@testset "AprilTag pipeline, stage by stage" begin

    @testset "the fixture itself is analytic" begin
        # Before anything is asserted THROUGH the pipeline, confirm the ground truth holds — that a
        # rendered frame really does put the disc where `image_xy` claims. Everything downstream
        # rests on this, so it is checked directly rather than assumed.
        ground = apriltag_ground()
        pose = k -> drone_pose(dx = 40sin(2π*(k-1)/9), dy = 30cos(2π*(k-1)/7),
                               yaw = deg2rad(15sin(2π*(k-1)/11)), cx = CENTRE, cy = CENTRE)
        v = make_apriltag_video(mktempdir(), "analytic"; nframes = 8, tw = TARGET_WIDTH, pose)
        for k in 1:8
            # per-frame testset: eight frames differ only by pose, so a failure has to say which
            # one drifted — and a throw inside the render is attributed to its frame too
            @testset "frame $k" begin
                img = render_pose(Fixtures.draw_disc(ground, v.groundpath[k]..., TARGET_WIDTH),
                                  v.poses[k], FRAME, FRAME)
                p = v.image_xy(k)
                box = CartesianIndices((round(Int, p[2]) - 20:round(Int, p[2]) + 20,
                                        round(Int, p[1]) - 20:round(Int, p[1]) + 20))
                dark = [i for i in box if img[i] < 0x40]     # the disc, with the tags out of the box
                centroid = SVector(sum(i -> i[2], dark) / length(dark), sum(i -> i[1], dark) / length(dark))
                @test norm(centroid - p) < 0.5
            end
        end
        # and the reference-space position really is pose-independent
        @test v.expected_ref(3) ≈ pose_apply(v.poses[1], v.ground_xy(3))
    end

    dir = mktempdir()

    @testset "stage 4 — a stationary camera reproduces the intended track exactly" begin
        # No drone motion at all: only the disc moves. Registration has nothing to cancel, so it
        # must come out as the identity to numerical precision, and the track is a pure test of
        # detection, the metric fit and the DoG tracker.
        f = check_flight(dir, "stationary", k -> drone_pose())
        @test maximum(norm(f.refpos[k] - f.v.expected_ref(k)) for k in 1:NFRAMES) < 1e-6
    end

    @testset "stage 5 — translation: registration inverts it and the track is unmoved" begin
        # The drone flies over the ground. Per frame the target moves ~30 px in the image — more
        # than a whole search window — and registration has to put all of it back.
        check_flight(dir, "translation",
                     k -> drone_pose(dx = 55sin(2π*(k-1)/12), dy = 45cos(2π*(k-1)/12));
                     teeth = true)
    end

    # Stage 6 — one drone degree of freedom at a time, each about the frame centre (where a drone
    # actually rotates). Isolated on purpose: if one of these regresses, the failing testset names
    # the axis. Their raw image motion is smaller than the translation flight's — the disc sits
    # near the centre, which is these transforms' fixed point — so the `teeth` assertion is left
    # to the flights that earn it, and what these prove is that each axis is INVERTED correctly.
    @testset "stage 6 — altitude (scale)" begin
        check_flight(dir, "scale", k -> drone_pose(zoom = 1 + 0.25sin(2π*(k-1)/15),
                                                   cx = CENTRE, cy = CENTRE))
    end

    @testset "stage 6 — yaw" begin
        check_flight(dir, "yaw", k -> drone_pose(yaw = deg2rad(25sin(2π*(k-1)/15)),
                                                 cx = CENTRE, cy = CENTRE))
    end

    @testset "stage 6 — pitch and roll" begin
        # the genuinely projective case: a tilted camera, so the ground plane is seen in
        # perspective and the homography's bottom row stops being (0, 0, 1)
        check_flight(dir, "pitchroll",
                     k -> drone_pose(pitch = deg2rad(14sin(2π*(k-1)/15)),
                                     roll = deg2rad(11cos(2π*(k-1)/15)),
                                     alt = 1000, cx = CENTRE, cy = CENTRE))
    end

    @testset "stage 6 — skew" begin
        check_flight(dir, "shear", k -> drone_pose(shear = 0.18sin(2π*(k-1)/15),
                                                   cx = CENTRE, cy = CENTRE))
    end

    @testset "stage 6 — all six degrees of freedom at once" begin
        # xy translation, altitude, yaw, pitch and roll together, on mutually prime periods so the
        # pose never repeats over the flight: the whole envelope a drone is expected to move in.
        check_flight(dir, "all6dof",
                     k -> drone_pose(dx = 35sin(2π*(k-1)/13), dy = 28cos(2π*(k-1)/11),
                                     zoom = 1 + 0.18sin(2π*(k-1)/17),
                                     yaw = deg2rad(18sin(2π*(k-1)/19)),
                                     pitch = deg2rad(10sin(2π*(k-1)/23)),
                                     roll = deg2rad(8cos(2π*(k-1)/29)),
                                     alt = 1000, cx = CENTRE, cy = CENTRE);
                     teeth = true)
    end

    @testset "no start_location: the centre search finds the target by itself" begin
        # The `start_location::Missing` branch of `apriltag_guess` — the only line of
        # src/PawsomeTracker/apriltag.jl the rest of the suite never reaches. It searches a box of
        # `min(canvas)/initial_search_factor` around the canvas centre, which here holds the disc
        # and none of the four tag blocks, so the tracker has to find the target unaided and the
        # run must still land on the same closed-form path as when it is handed a seed.
        v = make_apriltag_video(dir, "noseed"; nframes = NFRAMES, tw = TARGET_WIDTH,
                                pose = k -> drone_pose(dx = 30sin(2π*(k-1)/12),
                                                       dy = 24cos(2π*(k-1)/12)))
        file = joinpath(dir, v.file)
        rect = rectify(file)
        _, xy = track1(file; rectification = rect, target_width = TARGET_WIDTH)  # no start_location
        @test !any(ismissing, xy)
        expected(k) = rect.image2real(apply_h(rect.reference.M, v.expected_ref(k)))
        @test maximum(norm(xy[k] - expected(k)) for k in 1:NFRAMES) < TRACK_TOL
    end
end

end
