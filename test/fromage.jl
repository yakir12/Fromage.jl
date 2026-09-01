# End-to-end: a synthetic data folder (one checkerboard calibration video + one trackable run
# video + the two CSVs) driven through `main`, which validates both files, builds the
# rectification, tracks the run with the rectification attached, and writes the concatenated
# diagnostic video into results_dir under the current directory.
module FromageTests

using Test
using Random: Xoshiro
using Fromage
using DataFrames: DataFrame, nrow
using StaticArrays: SVector
using MAT: matwrite
using ..Fixtures
using ..Harness: capturing


@testset "Fromage end-to-end (main)" begin
    dir = mktempdir()

    # calibration video: the static 500×376 checkerboard used by the VerifyRectifications suite;
    # run video: the shared known-trajectory disc (defaults: 100×100, 2 s at 25 fps, start (55, 50))
    png = joinpath(@__DIR__, "VerifyRectifications", "fixtures", "checkerboard.png")
    make_checkerboard_video(joinpath(dir, "board.mp4"), png)
    target, expected = make_target_video(dir, "target")

    # n_corners and target_width are deliberately NOT in the CSVs: they arrive via main's global
    # defaults (the hardcoded n_corners (7, 10) would fail detection on the 5×8 board, so a clean
    # run proves the kwargs propagated into both gateways)
    open(joinpath(dir, "calibs.csv"), "w") do io
        println(io, "calibration_id,file,type,extrinsic,start,stop,checker_width")
        println(io, "c1,board.mp4,video,1,0,4,4")
    end
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "calibration_id,file,start_location")
        println(io, "c1,$(only(target)),\"(55, 50)\"")
    end

    # main writes results_dir/diagnostic.mp4 relative to the current directory
    outdir = mktempdir()
    runs = cd(() -> main(dir; rectification_defaults = (n_corners = (5, 8),),
                              tracking_defaults = (target_width = 10,),
                              rectification_diagnostics = true), outdir)

    @test runs isa DataFrame
    @test nrow(runs) == 1
    t, xy = only(runs.run)                          # track returns (timestamps, REAL-WORLD coords)
    @test length(xy) == 50                          # the full 2 s at 25 fps
    # ground truth is the analytic pixel path pushed through the same rectification
    real_expected(i; kw...) = Tuple(only(runs.rectification).image2real(SVector(expected(i; kw...)...)))
    @test tracking_rmse(xy, real_expected) < 0.3    # tracked vs ground truth, in real-world units
    @test only(runs.rectification).ratio > 0        # the joined rectification is a real one
    diag = joinpath(outdir, "results_dir", "diagnostic.mp4")
    @test isfile(diag)
    @test filesize(diag) > 0
    # rectification_diagnostics: one warped extrinsic frame per calibration, named by its id — so a
    # bad calibration is visible without watching the run through
    rectjpg = joinpath(outdir, "results_dir", "rectifications", "c1.jpg")
    @test isfile(rectjpg)
    @test filesize(rectjpg) > 0
    # the diagnostic contract: fixed square canvas, 2× real time — 50 tracked frames at 25 fps
    # write every 2nd frame, declared at 25 fps ⇒ 25 frames spanning 1 s of playback
    s = probe_stream(diag)
    @test (s.width, s.height) == (540, 540)
    @test s.nframes == 25
    @test s.fps ≈ 25
    @test s.duration ≈ 1.0 atol = 0.2
    # one track csv per run: time and the REAL-WORLD x/y (track already applied the rectification),
    # one row per detected coordinate (run_id imputed to "1")
    lines = readlines(joinpath(outdir, "results_dir", "1.csv"))
    @test length(lines) == 51                       # header + 50 coordinates
    @test lines[1] == "time,x,y"
    t0, x0, y0 = parse.(Float64, split(lines[2], ','))
    @test t0 == 0.0
    # the analytic ground-truth pixel, pushed through the same rectification (which returns
    # (y-direction, x-direction), mirroring its (row, col) input)
    gy, gx = only(runs.rectification).image2real(SVector(expected(1)...))
    @test x0 ≈ gx atol = 0.2
    @test y0 ≈ gy atol = 0.2
end

@testset "only_rectify / only_track (partial pipeline)" begin
    # The two iterate-on-your-csv helpers, each over the cheapest possible inputs: an only_scale
    # calibration (no checkerboard detection) and the shared known-trajectory disc video.
    dir = mktempdir()
    make_video(joinpath(dir, "cal.mp4"); size = (320, 240), duration = 2)
    target, expected = make_target_video(dir, "solo")
    open(joinpath(dir, "calibs.csv"), "w") do io
        println(io, "calibration_id,type,file,extrinsic,scale")
        println(io, "c1,only_scale,cal.mp4,1,2")
    end
    open(joinpath(dir, "runs.csv"), "w") do io
        # background_length = 0 rides along to prove the column flows csv → gateway → track
        println(io, "calibration_id,file,start_location,background_length")
        println(io, "c1,$(only(target)),\"(55, 50)\",0")
    end
    outdir = mktempdir()

    calibs = cd(() -> Fromage.only_rectify(dir), outdir)
    @test length(calibs) == 1
    rect = only(calibs)
    @test rect.ratio == 2                           # the csv's scale
    @test (rect.width, rect.height) == (320, 240)
    p = SVector(7.0, 11.0)
    @test rect.real2image(rect.image2real(p)) ≈ p   # the two maps are inverses
    # off by default, and off means no trace at all — not even the folder
    @test !ispath(joinpath(outdir, "results_dir", "rectifications"))

    # on request, one image per calibration here too — this time through the only_scale builder
    diagdir = mktempdir()
    cd(() -> Fromage.only_rectify(dir; rectification_diagnostics = true), diagdir)
    scalejpg = joinpath(diagdir, "results_dir", "rectifications", "c1.jpg")
    @test isfile(scalejpg)
    @test filesize(scalejpg) > 0

    # no rectification involved: raw pixel coordinates, one raw-view diagnostic per run, named by
    # run_id — which this csv does not set, so it is the imputed row number
    runs = cd(() -> Fromage.only_track(dir; tracking_defaults = (target_width = 10,)), outdir)
    @test length(runs) == 1
    _, ij = only(runs)
    @test length(ij) == 50                          # the full 2 s at 25 fps
    @test tracking_rmse(ij, expected) < 1
    diag = joinpath(outdir, "results_dir", "1.mp4")
    @test isfile(diag)
    @test filesize(diag) > 0

    # When the csv does name its runs, the diagnostic carries that name — and keeps it when a
    # filter drops an earlier run. Numbering by position instead would name this file "1.mp4",
    # which matches no row in the csv the user is looking at.
    open(joinpath(dir, "named.csv"), "w") do io
        println(io, "run_id,calibration_id,file,start_location,background_length")
        println(io, "solo_a,c1,$(only(target)),\"(55, 50)\",0")
        println(io, "solo_b,c1,$(only(target)),\"(55, 50)\",0")
    end
    named_out = mktempdir()
    cd(() -> Fromage.only_track(dir; runs_file = "named.csv", run_ids = ["solo_b"],
                                tracking_defaults = (target_width = 10,)), named_out)
    @test isfile(joinpath(named_out, "results_dir", "solo_b.mp4"))
    @test !isfile(joinpath(named_out, "results_dir", "1.mp4"))
end

@testset "an id filter that matches nothing is reported, not obeyed silently (#21)" begin
    # Filtering by id is a convenience for iterating on one run; an id that matches nothing is a
    # typo, not a request for less. Both the total miss (which would fail late and unhelpfully out
    # of ffmpeg) and the partial one (which would silently track fewer runs than asked) must be
    # reported here instead.
    dir = mktempdir()
    make_video(joinpath(dir, "cal.mp4"); size = (320, 240), duration = 2)
    target, _ = make_target_video(dir, "idf")
    open(joinpath(dir, "calibs.csv"), "w") do io
        println(io, "calibration_id,type,file,extrinsic,scale")
        println(io, "c1,only_scale,cal.mp4,1,2")
    end
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "run_id,calibration_id,file,start_location")
        println(io, "r1,c1,$(only(target)),\"(55, 50)\"")
    end
    outdir = mktempdir()

    # a total miss: named, and nothing about ffmpeg
    @test_throws "r_typo" cd(() -> main(dir; run_ids = ["r_typo"]), outdir)
    # a partial miss is an error too — strict, because a mistyped id is never intentional
    @test_throws "r_typo" cd(() -> main(dir; run_ids = ["r1", "r_typo"]), outdir)
    # the message says which ids exist, so the typo is obvious
    @test_throws "r1" cd(() -> main(dir; run_ids = ["r_typo"]), outdir)
    # both partial-pipeline helpers, which returned an empty vector with no error at all
    @test_throws "r_typo" cd(() -> Fromage.only_track(dir; run_ids = ["r_typo"]), outdir)
    @test_throws "c_typo" cd(() -> Fromage.only_rectify(dir; calibration_ids = ["c_typo"]), outdir)
    # and a filter that does match still works
    @test nrow(cd(() -> main(dir; run_ids = ["r1"], tracking_defaults = (target_width = 10,)), outdir)) == 1
end

@testset "Fromage end-to-end: AprilTag drone tracking" begin
    # The whole AprilTag path through `main`: a `type = apriltag` calibs row builds the shared
    # reference from the extrinsic frame; the run registers each frame to it (cancelling the drone
    # pan) and is reported in metric ground coordinates. Exercises detection, reference building,
    # motion cancellation, the metric scale (tag_cell_width = cell size), the centre/north gauge, and
    # the csv/diagnostic outputs — the pure geometry is unit-tested separately in test/apriltag.jl.
    dir = mktempdir()
    vid, groundpath, sl, nframes = make_apriltag_video(dir, "drone")
    open(joinpath(dir, "calibs.csv"), "w") do io
        println(io, "calibration_id,type,file,extrinsic,apriltags,family,tag_cell_width")
        println(io, "drone,apriltag,$vid,0,4,tag36h11,8")
    end
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "run_id,calibration_id,file,start_location,target_width")
        println(io, "beetle,drone,$vid,\"$sl\",12")
    end
    outdir = mktempdir()
    runs = cd(() -> main(dir), outdir)

    @test nrow(runs) == 1
    rect = only(runs.rectification)
    @test rect isa Fromage.PawsomeTracker.ApriltagRectification   # the joined rectification is the apriltag kind
    @test rect.ratio > 0
    ts, xy = only(runs.run)
    @test length(xy) == nframes
    @test !any(ismissing, xy)                          # every frame held all four tags (no gaps)
    # tag_cell_width = 8 ⇒ one metric unit = one ground pixel, so the tracked path is directly
    # comparable to the known straight ground path: the same total displacement (drone pan cancelled),
    # and straight (small deviation from its own chord).
    present = collect(skipmissing(xy))
    ground_disp = hypot((groundpath[end] .- groundpath[1])...)
    @test hypot((present[end] - present[1])...) ≈ ground_disp rtol = 0.05
    a, b = present[1], present[end]; d = (b - a) ./ hypot((b - a)...)
    @test maximum(abs((p - a)[1] * d[2] - (p - a)[2] * d[1]) for p in present) < 3   # within 3 cm of the line
    # the no-subtraction path (background_length = 0) through track_apriltag: the 2-slice
    # registered stack still cancels the pan, and the same displacement contract holds
    _, xy0 = track1(joinpath(dir, vid); rectification = rect,
        start_location = sl, target_width = 12, background_length = 0)
    @test !any(ismissing, xy0)
    p0 = collect(skipmissing(xy0))
    @test hypot((p0[end] - p0[1])...) ≈ ground_disp rtol = 0.05
    # outputs: one track csv (real-world x/y) and the shared diagnostic video
    lines = readlines(joinpath(outdir, "results_dir", "beetle.csv"))
    @test length(lines) == nframes + 1 && lines[1] == "time,x,y"
    diag = joinpath(outdir, "results_dir", "diagnostic.mp4")
    @test isfile(diag) && filesize(diag) > 0
    # nothing failed detection, so no frame was dumped — and the issues folder was never created
    @test !ispath(joinpath(outdir, "results_dir", "issues"))
end

@testset "AprilTag: registered stack survives a large pan, the rolling phase, and tag loss" begin
    # A harder synthetic flight than the e2e above, aimed at the registered background stack: a
    # large pan amplitude (the crop window sweeps nearly the whole canvas margin), more frames than
    # the background window (so the rolling phase runs at all — the e2e above fits entirely in the
    # prefill), and the first tag occluded both BEFORE the first full tag set (exercising the
    # backfilled pre-seed registrations) and inside the rolling phase (the borrowed ones). Driven
    # through `track` directly, with a start_location that must cross the seed frame's registration
    # to land on the reference-space stack.
    dir = mktempdir()
    occluded = vcat(1:3, 260:264)
    vid, groundpath, sl, nframes = make_apriltag_video(dir, "bigpan"; nframes = 300, amp = 55, occlude = occluded)
    file = joinpath(dir, vid)
    # extrinsic at t = 0.2 s (frame 6): the frames around t = 0 have the occluded tag
    rect = Fromage.PawsomeTracker.ApriltagRectification(; aspect = 1.0, file = file, extrinsic = 0.2, ntags = 4, family = "tag36h11",
        tag_cell_width = 8, center = missing, north = missing, width = 480, height = 480)
    ts, xy = track1(file; rectification = rect, start_location = sl, target_width = 12)
    @test length(xy) == nframes
    @test findall(ismissing, xy) == occluded            # a lost tag ⇒ missing, exactly there
    pidx = findall(!ismissing, xy)
    present = [xy[i] for i in pidx]
    # same accuracy contract as the e2e above (tag_cell_width = 8 ⇒ metric unit = ground px),
    # between the first and last frames that actually registered
    ground_disp = hypot((groundpath[pidx[end]] .- groundpath[pidx[1]])...)
    @test hypot((present[end] - present[1])...) ≈ ground_disp rtol = 0.05
    a, b = present[1], present[end]; d = (b - a) ./ hypot((b - a)...)
    @test maximum(abs((p - a)[1] * d[2] - (p - a)[2] * d[1]) for p in present) < 3
end

@testset "AprilTag: a segmented run, with one diagnostic spanning both segments" begin
    # The vector `track` method's AprilTag branch had no coverage at all — every other AprilTag test
    # drives the single-file method. That left the per-segment loop, the shared DiagnoseApriltag,
    # `reduce(vcat, segs)` and the timestamp stitching untested; the field case is a long drone
    # flight the camera split across files. Both segments are filmed over the same (stationary) tags,
    # so one shared reference registers both, which is the premise of AprilTag mode.
    dir = mktempdir()
    vidA, groundA, slA, nA = make_apriltag_video(dir, "segA"; nframes = 40)
    vidB, _, slB, nB = make_apriltag_video(dir, "segB"; nframes = 40)
    fileA, fileB = joinpath(dir, vidA), joinpath(dir, vidB)
    # the reference comes from segment A's extrinsic frame and serves both segments
    rect = Fromage.PawsomeTracker.ApriltagRectification(; aspect = 1.0, file = fileA, extrinsic = 0.2, ntags = 4, family = "tag36h11",
        tag_cell_width = 8, center = missing, north = missing, width = 480, height = 480)

    diag = joinpath(dir, "segmented.mp4")
    sls = Vector{Union{Missing, NTuple{2, Int}}}([slA, slB])
    ts, xy = track1([fileA, fileB]; rectification = rect, start_location = sls,
                    target_width = 12, diagnostic_file = diag)

    @test length(xy) == nA + nB                        # both segments, concatenated
    @test length(ts) == length(xy)
    # the stitched timestamps continue at the tracked rate across the join — the vector method
    # rebuilds the range from the first segment's step, so a wrong step shows up only here
    @test step(ts) ≈ 1 / 25 rtol = 1e-6
    @test first(ts) == 0

    # tags are visible throughout these fixtures, so every frame should have registered
    @test count(ismissing, xy) == 0
    # the coordinates are metric: the disc covers the same known ground distance in each segment,
    # so both halves must span the same distance (tag_cell_width = 8 ⇒ metric unit = ground px)
    ground_disp = hypot((groundA[nA] .- groundA[1])...)
    @test hypot((xy[nA] - xy[1])...) ≈ ground_disp rtol = 0.1
    @test hypot((xy[end] - xy[nA + 1])...) ≈ ground_disp rtol = 0.1

    # one diagnostic covers both segments and still plays at 2× real time over their combined
    # duration — the contract that was never checked for a spanning diagnostic
    @test isfile(diag) && filesize(diag) > 0
    s = probe_stream(diag)
    @test s.nframes / s.fps * 2 ≈ (nA + nB) / 25 rtol = 0.05
end

@testset "the AprilTag diagnostic carries the run's label (#22)" begin
    # `main` concatenates every run's diagnostic into one video, and a dataset of drone footage is
    # entirely AprilTag — so with no label, no segment of the combined video could be attributed to
    # a run, which is exactly what results.md tells the user to do with it.
    dir = mktempdir()
    vid, _, sl, _ = make_apriltag_video(dir, "lbl"; nframes = 40)
    file = joinpath(dir, vid)
    PT = Fromage.PawsomeTracker
    rect = PT.ApriltagRectification(; aspect = 1.0, file = file, extrinsic = 0.2, ntags = 4, family = "tag36h11",
        tag_cell_width = 8, center = missing, north = missing, width = 480, height = 480)

    # the label is the diagnostic file's name — which `main` sets to the run_id
    dia = PT.diagnose_apriltag(joinpath(dir, "run7.mp4"), rect.reference, true, 25)
    @test dia.label == "run7"
    close(dia)

    # and it reaches the *pixels*: two diagnostics differing only in file name must differ in
    # content. The encoder is deterministic, so before the label they came out byte-identical.
    outs = map(("aaaa", "wwww")) do name
        d = joinpath(dir, "$name.mp4")
        track1(file; rectification = rect, start_location = sl, target_width = 12,
               diagnostic_file = d)
        read(d)
    end
    @test outs[1] != outs[2]
end

@testset "AprilTag calibration: failing extrinsic frame is dumped to the issues folder" begin
    # the video has four tags; asking for six fails detection at the extrinsic frame, and the frame
    # is dumped to the issues folder (pointed at a temp dir) for the user to inspect. Each run dumps
    # into a time-stamped folder of its own, and Fromage never deletes anything in the folder it was
    # given (#86): a second run adds a second folder, leaving the first run's frame — and whatever
    # the user keeps there — untouched.
    dir = mktempdir(); idir = mktempdir()
    keepsake = joinpath(idir, "my_notes.txt")          # the user's own file, in the folder they named
    write(keepsake, "hands off")
    vid, _, _, _ = make_apriltag_video(dir, "drone")
    open(joinpath(dir, "calibs.csv"), "w") do io
        println(io, "calibration_id,type,file,extrinsic,apriltags,family,tag_cell_width")
        println(io, "drone,apriltag,$vid,0,6,tag36h11,12")
    end
    verify() = Fromage.VerifyRectifications.load_rectifications(dir, joinpath(dir, "calibs.csv"); strict = false, issues_dir = idir)
    run_dirs() = filter(isdir, readdir(idir; join = true))
    frames(d) = filter(endswith(".png"), readdir(d; join = true))

    df = verify()
    @test any(m -> occursin("only 4 of 6 AprilTags", m), only(df.issues))
    @test any(m -> occursin("saved the extrinsic frame", m), only(df.issues))
    first_run = only(run_dirs())
    @test length(frames(first_run)) == 1 && filesize(only(frames(first_run))) > 0

    df2 = verify()
    @test any(m -> occursin("saved the extrinsic frame", m), only(df2.issues))
    both = run_dirs()
    @test length(both) == 2 && first_run in both       # the second run added a folder, it didn't replace one
    @test all(d -> length(frames(d)) == 1, both)       # each folder holds only its own run's frame
    @test isfile(only(frames(first_run)))              # the first run's frame survived the second run
    @test read(keepsake, String) == "hands off"        # and so did the user's file
end

@testset "issue folders never collide" begin
    # run_issues_dir names a folder for the second the run started and counts past any folder that
    # second already has, which is what keeps back-to-back runs apart. It only names the folder —
    # save_issue_frame creates it — so a run with nothing to report leaves the issues folder alone.
    P = Fromage.Paths
    d = mktempdir()
    a = P.run_issues_dir(d); mkpath(a)
    b = P.run_issues_dir(d); mkpath(b)
    c = P.run_issues_dir(d)
    @test allunique((a, b, c))
    @test all(==(d) ∘ dirname, (a, b, c))
    @test !ispath(c)
    # no colons in the stamp: these paths have to be creatable on Windows too
    @test !occursin(':', basename(a))
end

@testset "reference_frame reports failures, and only the builder throws" begin
    # reference_frame returns Union{ReferenceFrame, String}: every way a calibration can fail to
    # yield a shared reference is a fact about the user's file, so it is reported, not thrown.
    PT = Fromage.PawsomeTracker
    dir = mktempdir()
    vid, _, _, _ = make_apriltag_video(dir, "ref"; nframes = 20)
    file = joinpath(dir, vid)
    corrupt = make_corrupt_video(joinpath(dir, "corrupt.mp4"))

    @test PT.reference_frame(file, 0.2, 4, "tag36h11", 8)    isa PT.ReferenceFrame   # success
    @test PT.reference_frame(file, 0.2, 99, "tag36h11", 8)   isa String              # too few tags
    @test PT.reference_frame(file, 0.2, 4, "tag99x9", 8)     isa String              # unsupported family
    @test PT.reference_frame(corrupt, 0.2, 4, "tag36h11", 8) isa String              # unreadable frame

    # the verification hook is now a plain type test, with no catch of its own
    @test PT.apriltag_extrinsic_issue(file, 0.2, 4, "tag36h11", 8)    === nothing
    @test PT.apriltag_extrinsic_issue(file, 0.2, 99, "tag36h11", 8)   isa String
    @test PT.apriltag_extrinsic_issue(corrupt, 0.2, 4, "tag36h11", 8) isa String

    # ...while the rectification builder, which has nowhere to put a message, still throws
    @test_throws ErrorException PT.ApriltagRectification(; aspect = 1.0, file = corrupt, extrinsic = 0.2, ntags = 4, family = "tag36h11",
        tag_cell_width = 8, center = missing, north = missing, width = 480, height = 480)
    @test_throws ErrorException PT.ApriltagRectification(; aspect = 1.0, file = file, extrinsic = 0.2, ntags = 99, family = "tag36h11",
        tag_cell_width = 8, center = missing, north = missing, width = 480, height = 480)
end

@testset "diagnostic video: multi-run, mixed calibrations" begin
    # All three rectification kinds in one pipeline run: two only_scale rectifications on
    # different-sized source videos — the case the fixed canvas exists for, since a mixed-resolution
    # diagnostic cannot be stream-copied — plus a matlab rectification read from a .mat file.
    dir = mktempdir()
    make_video(joinpath(dir, "cal_big.mp4"); size = (640, 480))
    make_video(joinpath(dir, "cal_small.mp4"); size = (320, 240))
    # fronto-parallel pinhole; ImageSize [480, 640] matches cal_big.mp4 (the cross-check)
    matwrite(joinpath(dir, "cal.mat"), Dict("cameraParams" => Dict(
        "ImageSize" => [480.0, 640.0],
        "K" => [500.0 0.0 320.0; 0.0 500.0 240.0; 0.0 0.0 1.0],
        "RotationVectors" => zeros(2, 3),
        "TranslationVectors" => [0.0 0.0 100.0; 0.0 0.0 200.0],
        "RadialDistortion" => [0.0, 0.0])))
    targets = [make_target_video(dir, "t$i") for i in 1:4]
    open(joinpath(dir, "calibs.csv"), "w") do io
        println(io, "calibration_id,type,file,extrinsic,scale,matlab_file,extrinsic_index")
        println(io, "c1,only_scale,cal_big.mp4,1,1,,")
        println(io, "c2,only_scale,cal_small.mp4,1,1,,")
        println(io, "m1,matlab,cal_big.mp4,1,,cal.mat,1")
    end
    calib_ids = ("c1", "c1", "c2", "m1")
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "run_id,calibration_id,file,start_location")
        for (i, (files, _)) in enumerate(targets)
            println(io, "run$i,$(calib_ids[i]),$(only(files)),\"(55, 50)\"")
        end
    end
    outdir = mktempdir()
    runs = cd(() -> main(dir; tracking_defaults = (target_width = 10,)), outdir)
    @test nrow(runs) == 4
    diag = joinpath(outdir, "results_dir", "diagnostic.mp4")
    sizes, pts, dts = probe_frames(diag)
    @test sizes == Set([(540, 540)])                # one resolution across every frame
    @test length(pts) == 4 * 25                     # 4 runs × 25 written frames each
    @test all(diff(dts) .> 0)                       # decode order strictly monotonic across joins
    @test allunique(pts)                            # every frame has its own presentation time
    # one track csv per run, named by run_id
    for i in 1:4
        lines = readlines(joinpath(outdir, "results_dir", "run$i.csv"))
        @test length(lines) == 51                   # header + 50 coordinates
        @test lines[1] == "time,x,y"
    end
end

@testset "an apostrophe in a segment path survives the concat list" begin
    # ffmpeg takes each path in the concat list single-quoted, so an unescaped apostrophe closed the
    # line early and the segment after it was silently dropped. An apostrophe is a legal file-name
    # character and a plausible run_id ("beetle's run"), so it is escaped rather than rejected — and
    # asserted against real ffmpeg here, since the escaping is ffmpeg's rule and not ours to assume.
    dir = mktempdir()
    segs = map(1:2) do k
        f = joinpath(dir, "beetle's run $k.mp4")
        make_video(f; duration = 1, size = (64, 64), rate = 5)
        f
    end
    outdir = mktempdir()
    cd(outdir) do
        mkpath("results_dir")                       # `main` makes it; this calls concatenate directly
        Fromage.concatenate(dir, segs)
    end
    joined = joinpath(outdir, "results_dir", "diagnostic.mp4")
    @test isfile(joined)
    # both 5-frame segments, not just the one before the apostrophe broke the line
    @test probe_stream(joined).nframes == 10
end

# `strict = false` is the debugging mode: report everything wrong with both files and hand them
# back, rather than stopping at the first one (#121).
@testset "main(strict = false) reports both files instead of aborting" begin
    dir = mktempdir()
    make_video(joinpath(dir, "cal.mp4"); size = (320, 240), duration = 2)
    target, _ = make_target_video(dir, "nonstrict")
    open(joinpath(dir, "calibs.csv"), "w") do io
        println(io, "calibration_id,type,file,extrinsic,scale")
        println(io, "c1,only_scale,cal.mp4,1,2")
        println(io, "c1,only_scale,cal.mp4,1,2")     # duplicate id: a first-tier failure
    end
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "calibration_id,file,start_location")
        println(io, "c1,$(only(target)),\"(55, 50)\"")
    end
    outdir = mktempdir()

    @test_throws "there were issues" cd(() -> main(dir), outdir)      # the default still aborts

    # A dataset is accepted or rejected as a whole, so both tables come back annotated — handing
    # back built runs whose calibration was just rejected would imply a usability they lack (#122).
    out = cd(() -> main(dir; strict = false), outdir)
    @test out.calibs isa DataFrame
    @test out.runs isa DataFrame
    @test hasproperty(out.calibs, :issues)
    @test hasproperty(out.runs, :issues)
    @test any(!isempty, out.calibs.issues)                            # the offending file
    @test all(isempty, out.runs.issues)                               # runs.csv itself was clean
end

# The two csv files must describe one dataset: every run's calibration exists, and every calibration
# is used (#122). Both are first-tier checks, so an incoherent pair costs no video reads at all.
@testset "calibs.csv and runs.csv must be coherent" begin
    dir = mktempdir()
    make_video(joinpath(dir, "cal.mp4"); size = (320, 240), duration = 2)
    # seeded, like every other fixture: random bytes are unreadable whatever they are, but an
    # unseeded one cannot be reproduced from a failing log
    write(joinpath(dir, "broken.mp4"), rand(Xoshiro(20260901), UInt8, 4096))   # unreadable: probing it is loud
    target, _ = make_target_video(dir, "coh")
    outdir = mktempdir()

    @testset "a calibration no run uses is rejected, before anything is opened" begin
        write(joinpath(dir, "calibs.csv"),
              "calibration_id,type,file,extrinsic,scale\nc1,only_scale,cal.mp4,1,2\nc2,only_scale,broken.mp4,1,2\n")
        write(joinpath(dir, "runs.csv"),
              "calibration_id,file,start_location\nc1,$(only(target)),\"(55, 50)\"\n")
        _, out = capturing() do
            try
                cd(() -> main(dir; tracking_defaults = (target_width = 10,)), outdir)
            catch e
                e
            end
        end
        @test occursin("calibration_id c2 is not used by any row in runs.csv", out)
        # the unused calibration points at an unreadable video; probing it would say so loudly, so
        # this silence is what proves the first tier stopped before any read
        @test !occursin("issue reading from video file", out)
    end

    @testset "a run naming a calibration that does not exist is rejected, and both files reported" begin
        write(joinpath(dir, "calibs.csv"),
              "calibration_id,type,file,extrinsic,scale\nc1,only_scale,cal.mp4,1,2\n")
        write(joinpath(dir, "runs.csv"),
              "calibration_id,file,start_location\nc9,$(only(target)),\"(55, 50)\"\n")
        _, out = capturing() do
            try
                cd(() -> main(dir; tracking_defaults = (target_width = 10,)), outdir)
            catch e
                e
            end
        end
        # both halves are reported in one pass: together they diagnose the typo
        @test occursin("references calibration_id c9, which is not in calibs.csv", out)
        @test occursin("calibration_id c1 is not used by any row in runs.csv", out)
    end
end

# Coherence is a property of the files AS WRITTEN, checked before `run_ids` narrows anything —
# otherwise asking for one run would fail the calibrations it did not ask for (#122).
@testset "run_ids still narrows a coherent multi-calibration folder" begin
    dir = mktempdir()
    make_video(joinpath(dir, "cal1.mp4"); size = (320, 240), duration = 2)
    make_video(joinpath(dir, "cal2.mp4"); size = (320, 240), duration = 2)
    t1, _ = make_target_video(dir, "n1")
    t2, _ = make_target_video(dir, "n2")
    write(joinpath(dir, "calibs.csv"),
          "calibration_id,type,file,extrinsic,scale\nc1,only_scale,cal1.mp4,1,2\nc2,only_scale,cal2.mp4,1,2\n")
    write(joinpath(dir, "runs.csv"),
          "run_id,calibration_id,file,start_location\n" *
          "r1,c1,$(only(t1)),\"(55, 50)\"\nr2,c2,$(only(t2)),\"(55, 50)\"\n")
    outdir = mktempdir()

    runs = cd(() -> main(dir; run_ids = ["r1"], tracking_defaults = (target_width = 10,)), outdir)
    @test nrow(runs) == 1                       # only the run asked for
    @test only(runs.run_id) == "r1"
    @test only(runs.calibration_id) == "c1"     # and only the calibration it needs
end

end
