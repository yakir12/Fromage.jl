# End-to-end: a synthetic data folder (one checkerboard calibration video + one trackable run
# video + the two CSVs) driven through `main`, which validates both files, builds the
# rectification, tracks the run with the rectification attached, and writes the concatenated
# diagnostic video into results_dir under the current directory.
module FromageTests

using Test
using Random: Xoshiro
using Fromage
using DataFrames: DataFrame
using Statistics: mean
using StaticArrays: SVector
using MAT: matwrite
using ..Fixtures
using ..Harness: capturing

# `main` returns nothing (#256): everything a test asserts about a run is read from what `main` wrote.
# This reads one run's `results_dir/<run_id>.csv` back into `track`'s values and order — timestamps,
# and coordinates in `track`'s own `(y, x)` order, which `save2csv` writes out as `x,y` columns and
# this swaps back — as plain `Vector`s, the coordinates admitting `missing`: a row with empty `x`/`y`
# is a frame `track` could not localize. `save2csv` prints each `Float64` in full, so the values
# round-trip exactly and no tolerance below had to move to absorb it. The header is checked because
# the swap depends on the column order it names.
function read_track(file)
    header, lines... = readlines(file)
    header == "time,x,y" || error("$file: expected the header time,x,y, got $(repr(header))")
    rows = split.(lines, ',')
    ts = [parse(Float64, t) for (t, _, _) in rows]
    coords = Union{Missing, SVector{2, Float64}}[
        isempty(x) ? missing : SVector(parse(Float64, y), parse(Float64, x)) for (_, x, y) in rows
    ]
    return ts, coords
end

# The rectification `main` built for the row `rectification_id` names, rebuilt here for a ground
# truth to go through. The row is parsed into the same `RectificationMethod` `main` built from, and
# goes through the same memoized builder, so within one session this is the very object `main`
# tracked through — which the callers assert on the memo's hit counter rather than take on trust.
function rebuilt_rectification(csv, rectification_id; defaults = (;))
    cs = Fromage.VerifyRectifications.load_rectifications(
        dirname(csv), csv; defaults, results_dir = mktempdir(), progress = true
    )
    return Fromage.build_rectification(only(filter(c -> c.rectification_id == rectification_id, cs)))
end

@testset "the narrowing entry points are gone, and nothing replaced them (#256)" begin
    @test !isdefined(Fromage, :only_track)
    @test !isdefined(Fromage, :only_rectify)
end


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
    open(joinpath(dir, "rectifications.csv"), "w") do io
        println(io, "rectification_id,file,type,extrinsic,intrinsic_start,intrinsic_stop,checker_width,custom_feature")
        println(io, "c1,board.mp4,checkerboard,1,0,4,4,metadata")
    end
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "rectification_id,file,start_location,animal_id")
        println(io, "c1,$(only(target)),\"(55, 50)\",beetle-1")
    end

    # with no `results_dir`, main writes results_dir/diagnostic.mp4 relative to the current directory
    outdir = mktempdir()
    returned = cd(
        () -> main(
            dir; rectification_defaults = (n_corners = (5, 8),),
            tracking_defaults = (target_width = 10,),
            rectification_diagnostics = true
        ), outdir
    )

    @test returned === nothing                      # everything main produces is on disk (#256)
    @test readdir(joinpath(outdir, "results_dir"); sort = true) ==
        ["1.csv", "diagnostic.mp4", "rectifications"]   # one run, so one track csv (run_id imputed to "1")
    hits = Fromage.Memo.hits(Fromage.Memo.BUILT_RECTIFICATIONS)
    rectification = cd(
        () -> rebuilt_rectification(joinpath(dir, "rectifications.csv"), "c1"; defaults = (n_corners = (5, 8),)),
        outdir
    )
    @test Fromage.Memo.hits(Fromage.Memo.BUILT_RECTIFICATIONS) == hits + 1   # main's own object, served
    t, xy = read_track(joinpath(outdir, "results_dir", "1.csv"))   # the REAL-WORLD coords track returned
    @test length(xy) == 50                          # the full 2 s at 25 fps
    # ground truth is the analytic pixel path pushed through the same rectification
    real_expected(i; kw...) = Tuple(rectification.image2real(SVector(expected(i; kw...)...)))
    @test tracking_rmse(xy, real_expected) < 0.3    # tracked vs ground truth, in real-world units
    @test rectification.ratio > 0                   # a real rectification, not a degenerate one
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
    gy, gx = rectification.image2real(SVector(expected(1)...))
    @test x0 ≈ gx atol = 0.2
    @test y0 ≈ gy atol = 0.2
end

@testset "Fromage end-to-end (main): anamorphic calibration and tracking (#278)" begin
    dir = mktempdir()
    sar = 2 // 1
    n_corners = (7, 6)
    checker_width = 25.0
    f = 1000.0
    width, height = 640, 480
    extrinsic_pose = 13
    poses = CHECKERBOARD_POSES

    board_path(k) = SVector(
        2.0 + 0.8 * sin(0.4π * (k - 1) / 30),
        4.0 + 0.3 * cos(0.4π * (k - 1) / 30),
    )
    make_squeezed_checkerboard_video(
        joinpath(dir, "board.mp4"), poses;
        sar, n_corners, f, width, height
    )
    target_clip = make_squeezed_disc_video(
        joinpath(dir, "target.mp4"), poses[extrinsic_pose];
        board_path, nframes = 30, diameter = 0.4, sar, f, width, height
    )

    open(joinpath(dir, "rectifications.csv"), "w") do io
        println(io, "rectification_id,file,type,extrinsic,intrinsic_start,intrinsic_stop,center,north,checker_width,temporal_step,radial_parameters")
        println(io, "c1,board.mp4,checkerboard,1.15,0.05,1.05,\"(320,240)\",\"(320,140)\",$checker_width,0.1,1")
    end
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "run_id,rectification_id,file,start_location,window_size")
        row, col = target_clip.stored(board_path(1)...)
        start_x = round(Int, (col + 0.5) * sar - 0.5)
        start_y = round(Int, row)
        println(io, "anamorphic,c1,target.mp4,\"($start_x,$start_y)\",\"(80,40)\"")
    end

    outdir = mktempdir()
    cd(
        () -> main(
            dir;
            rectification_defaults = (; n_corners),
            tracking_defaults = (; target_width = 20),
        ), outdir
    )

    t, xy = read_track(joinpath(outdir, "results_dir", "anamorphic.csv"))
    @test length(t) == 30
    @test all(!ismissing, xy)

    # The expected track is built from the fixture's independent board inverse. The declared
    # center/north gauge makes real coordinates board (Y, X), centred at the independently
    # projected display point (320, 240), then scaled to millimetres.
    center_board = target_clip.board(320, 240)
    expected(k) = begin
        point = board_path(k)
        SVector(point[2] - center_board[2], point[1] - center_board[1]) * checker_width
    end
    rmse = sqrt(mean(sum(abs2, Tuple(xy[k]) .- Tuple(expected(k))) for k in eachindex(xy)))
    @test rmse < 0.3
    @test probe_stream(joinpath(outdir, "results_dir", "diagnostic.mp4")).width == 540
end

@testset "an id filter that matches nothing is reported, not obeyed silently (#21)" begin
    # Filtering by id is a convenience for iterating on one run; an id that matches nothing is a
    # typo, not a request for less. Both the total miss (which would fail late and unhelpfully out
    # of ffmpeg) and the partial one (which would silently track fewer runs than asked) must be
    # reported here instead.
    dir = mktempdir()
    make_video(joinpath(dir, "cal.mp4"); size = (320, 240), duration = 2)
    target, _ = make_target_video(dir, "idf")
    open(joinpath(dir, "rectifications.csv"), "w") do io
        println(io, "rectification_id,type,file,extrinsic,pixel_width")
        println(io, "c1,uniform,cal.mp4,1,2")
    end
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "run_id,rectification_id,file,start_location")
        println(io, "r1,c1,$(only(target)),\"(55, 50)\"")
    end
    outdir = mktempdir()

    # a total miss: named, and nothing about ffmpeg
    @test_throws "r_typo" cd(() -> main(dir; run_ids = ["r_typo"]), outdir)
    # a partial miss is an error too — strict, because a mistyped id is never intentional
    @test_throws "r_typo" cd(() -> main(dir; run_ids = ["r1", "r_typo"]), outdir)
    # the message says which ids exist, so the typo is obvious
    @test_throws "r1" cd(() -> main(dir; run_ids = ["r_typo"]), outdir)
    # and a filter that does match still works
    cd(() -> main(dir; run_ids = ["r1"], tracking_defaults = (target_width = 10,)), outdir)
    @test isfile(joinpath(outdir, "results_dir", "r1.csv"))
end

@testset "Fromage end-to-end: AprilTag drone tracking" begin
    # The whole AprilTag path through `main`: a `type = apriltag` rectifications.csv row builds the shared
    # reference from the extrinsic frame; the run registers each frame to it (cancelling the drone
    # pan) and is reported in metric ground coordinates. Exercises detection, reference building,
    # motion cancellation, the metric scale (tag_cell_width = cell size), the centre/north gauge, and
    # the csv/diagnostic outputs — the pure geometry is unit-tested separately in test/apriltag.jl.
    dir = mktempdir()
    vid, groundpath, sl, nframes = make_apriltag_video(dir, "drone")
    open(joinpath(dir, "rectifications.csv"), "w") do io
        println(io, "rectification_id,type,file,extrinsic,apriltags,family,tag_cell_width")
        println(io, "drone,apriltag,$vid,0,4,tag36h11,8")
    end
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "run_id,rectification_id,file,start_location,target_width")
        println(io, "beetle,drone,$vid,\"$sl\",12")
    end
    outdir = mktempdir()
    # `rectification_diagnostics = true` deliberately: `build_rectifications` renders the warped
    # extrinsic frame from whatever the builder returned, and this kind has no fixed image→real map
    # to warp one through — its top-down diagnostic is the per-run video below instead. So asking
    # for the image here must be a quiet no-op (the `save_diagnostic` arm in PawsomeTracker/apriltag.jl),
    # not a MethodError, and it must leave no trace. This is the only apriltag row in the suite that
    # asks.
    cd(() -> main(dir; rectification_diagnostics = true), outdir)

    @test !ispath(joinpath(outdir, "results_dir", "rectifications"))   # asked for, and rightly absent
    @test count(endswith(".csv"), readdir(joinpath(outdir, "results_dir"))) == 1   # the one run
    hits = Fromage.Memo.hits(Fromage.Memo.BUILT_RECTIFICATIONS)
    rect = cd(() -> rebuilt_rectification(joinpath(dir, "rectifications.csv"), "drone"), outdir)
    @test Fromage.Memo.hits(Fromage.Memo.BUILT_RECTIFICATIONS) == hits + 1    # main's own object, served
    @test rect isa Fromage.PawsomeTracker.ApriltagRectification   # the row built the apriltag kind
    @test rect.ratio > 0
    ts, xy = read_track(joinpath(outdir, "results_dir", "beetle.csv"))
    @test length(xy) == nframes
    @test !any(ismissing, xy)                          # every frame held all four tags (no gaps)
    # tag_cell_width = 8 ⇒ one metric unit = one ground pixel, so the tracked path is directly
    # comparable to the known straight ground path: the same total displacement (drone pan cancelled),
    # and straight (small deviation from its own chord).
    present = collect(skipmissing(xy))
    ground_disp = hypot((groundpath[end] .- groundpath[1])...)
    @test hypot((present[end] - present[1])...) ≈ ground_disp rtol = 0.05
    a, b = present[1], present[end]; d = (b - a) ./ hypot((b - a)...)
    # Straightness, in GROUND PIXELS — not cm. The fixture sets `tag_cell_width` to the same value
    # as its `TAG_CELL` ground-pixel cell, which makes one recovered metric unit exactly one ground
    # pixel (`rect.ratio` measures 1.0000019); "cm" is only the unit label the pipeline carries.
    # Measured max deviation from the tracked chord: 0.091 here, 0.115 on the 300-frame occluded
    # flight below — bit-identical over 5 runs and at 1, 2 and 32 threads. Half a ground pixel is
    # ~4x that, which survives a detector or encoder rebuild while still failing a track that has
    # actually bent; `< 3` passed a track wandering a full pixel off its own chord.
    @test maximum(abs((p - a)[1] * d[2] - (p - a)[2] * d[1]) for p in present) < 0.5
    # the no-subtraction path (background_length = 0) through track_apriltag: the 2-slice
    # registered stack still cancels the pan, and the same displacement contract holds
    _, xy0 = track1(
        joinpath(dir, vid); rectification = rect,
        start_location = sl, target_width = 12, background_length = 0
    )
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
    rect = Fromage.PawsomeTracker.ApriltagRectification(;
        aspect = 1.0, file = file, extrinsic = 0.2, ntags = 4, family = "tag36h11",
        tag_cell_width = 8, center = missing, north = missing, width = 480, height = 480
    )
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
    # ground pixels, as above; measured 0.115 on this 300-frame flight with tag occlusions
    @test maximum(abs((p - a)[1] * d[2] - (p - a)[2] * d[1]) for p in present) < 0.5
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
    rect = Fromage.PawsomeTracker.ApriltagRectification(;
        aspect = 1.0, file = fileA, extrinsic = 0.2, ntags = 4, family = "tag36h11",
        tag_cell_width = 8, center = missing, north = missing, width = 480, height = 480
    )

    diag = joinpath(dir, "segmented.mp4")
    sls = Vector{Union{Missing, NTuple{2, Int}}}([slA, slB])
    ts, xy = track1(
        [fileA, fileB]; rectification = rect, start_location = sls,
        target_width = 12, diagnostic_file = diag
    )

    @test length(xy) == nA + nB                        # both segments, concatenated
    @test length(ts) == length(xy)
    # the stitched timestamps continue at the tracked rate across the join — the vector method
    # rebuilds the range from the first segment's step, so a wrong step shows up only here
    @test step(ts) ≈ 1 / 25 rtol = 1.0e-6
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
    # An exact frame count, not a tolerance: this is integer arithmetic, and the regression the
    # testset exists to catch is a frame DROPPED at the segment join. `rtol = 0.05` on 3.2 s admits
    # ±0.16 s while one diagnostic frame is 2/25 = 0.08 s, so it passed a diagnostic that was a
    # whole frame short — measured 0.0 residual, and vacuous anyway.
    @test s.nframes == (nA + nB) ÷ 2
    @test s.fps ≈ 25 rtol = 1.0e-6
    # Two files, so segment B's file time restarts at zero while the run's clock carries on from
    # 1.6 s: the label must show the former, with B's segment number.
    samples = [(k, (i - 1) / 25) for (k, n) in ((1, nA), (2, nB)) for i in 1:n]
    run_time = [(n - 1) / 25 for n in 1:(nA + nB)]
    candidates = unique([(k, t) for k in 1:2 for t in run_time])
    font = Fromage.PawsomeTracker.DIAGNOSTIC_SIZE ÷ 16          # the AprilTag scene's font, in `diagnose_apriltag`
    @test read_labels(diag, candidates, font) == samples[1:2:end]
end

@testset "the AprilTag diagnostic carries the run's label (#22)" begin
    # `main` concatenates every run's diagnostic into one video, and a dataset of drone footage is
    # entirely AprilTag — so with no label, no segment of the combined video could be attributed to
    # a run, which is exactly what results.md tells the user to do with it.
    dir = mktempdir()
    vid, _, sl, _ = make_apriltag_video(dir, "lbl"; nframes = 40)
    file = joinpath(dir, vid)
    PT = Fromage.PawsomeTracker
    rect = PT.ApriltagRectification(;
        aspect = 1.0, file = file, extrinsic = 0.2, ntags = 4, family = "tag36h11",
        tag_cell_width = 8, center = missing, north = missing, width = 480, height = 480
    )

    # the label is the diagnostic file's name — which `main` sets to the run_id
    dia = PT.diagnose_apriltag(joinpath(dir, "run7.mp4"), rect, true, 25)
    @test dia.label == "run7"
    font = dia.font                         # the size the label region below is worked out at
    close(dia)

    # The do-block form's cleanup (#160), on the mode that does NOT go through `diagnose`: a failed
    # AprilTag export closes its writer and takes its half-written file with it, exactly as the
    # video path does. Both go through `with_diagnostic`, and this is what says so.
    failed = joinpath(dir, "aprilfail.mp4")
    err = @test_throws ErrorException PT.diagnose_apriltag(failed, rect, true, 25) do _
        error("injected apriltag export failure")
    end
    @test err.value.msg == "injected apriltag export failure"
    @test !isfile(failed)

    # and it reaches the *pixels*. The same video tracked three times, differing only in the
    # diagnostic's file name — `aaaa` twice, into separate folders, and `wwww` once — and decoded,
    # because encoding is not byte-reproducible on every runner (#262), so unequal bytes would prove
    # nothing. Different names must differ inside the label's region and match everywhere else; the
    # same name encoded twice must match inside it too, so the tolerance separates a changed label
    # from encoding noise rather than passing anything; the two thresholds, and what they were
    # measured against, are in the fixtures beside `label_differences`.
    function render(name, folder)
        out = joinpath(mkpath(joinpath(dir, folder)), "$name.mp4")
        track1(
            file; rectification = rect, start_location = sl, target_width = 12,
            diagnostic_file = out
        )
        return out
    end
    a, w, again = render("aaaa", "first"), render("wwww", "first"), render("aaaa", "second")
    label, elsewhere = label_differences(a, w, ("aaaa", "wwww"), font)
    @test all(>(LABEL_CHANGED), label)
    @test all(<(ENCODING_NOISE), elsewhere)
    @test all(<(ENCODING_NOISE), vcat(label_differences(a, again, ("aaaa", "wwww"), font)...))
end

@testset "AprilTag calibration: failing extrinsic frame is dumped to the issues folder" begin
    # the video has four tags; asking for six fails detection at the extrinsic frame, and the frame
    # is dumped to the issues folder (pointed at a temp dir) for the user to inspect. Each run dumps
    # into a time-stamped folder of its own, and Fromage never deletes anything in the folder it was
    # given (#86): a second run adds a second folder, leaving the first run's frame — and whatever
    # the user keeps there — untouched.
    dir = mktempdir(); idir = mktempdir()
    keepsake = joinpath(mkpath(joinpath(idir, "issues")), "my_notes.txt")   # the user's own file, beside the frames
    write(keepsake, "hands off")
    vid, _, _, _ = make_apriltag_video(dir, "drone")
    open(joinpath(dir, "rectifications.csv"), "w") do io
        println(io, "rectification_id,type,file,extrinsic,apriltags,family,tag_cell_width")
        println(io, "drone,apriltag,$vid,0,6,tag36h11,12")
    end
    # named for what it does here; `verify` is now an exported entry point of its own
    check_calibs() = Fromage.VerifyRectifications.check_rectifications(
        dir, joinpath(dir, "rectifications.csv"); defaults = (;), results_dir = idir, progress = true
    )
    invocation_dirs() = filter(isdir, readdir(joinpath(idir, "issues"); join = true))
    frames(d) = filter(endswith(".png"), readdir(d; join = true))

    df = check_calibs()
    @test any(m -> occursin("only 4 of 6 AprilTags", m), only(df.issues))
    @test any(m -> occursin("saved the extrinsic frame", m), only(df.issues))
    first_invocation = only(invocation_dirs())
    @test length(frames(first_invocation)) == 1 && filesize(only(frames(first_invocation))) > 0

    # The second call is also the memo's guard (#233): the DETECTION is served from the cache by
    # then, and the frame dump must still happen, into this invocation's own folder.
    df2 = check_calibs()
    @test any(m -> occursin("saved the extrinsic frame", m), only(df2.issues))
    both = invocation_dirs()
    @test length(both) == 2 && first_invocation in both       # the second run added a folder, it didn't replace one
    @test all(d -> length(frames(d)) == 1, both)       # each folder holds only its own run's frame
    @test isfile(only(frames(first_invocation)))              # the first run's frame survived the second run
    @test read(keepsake, String) == "hands off"        # and so did the user's file
end

@testset "issue folders never collide" begin
    # invocation_issues_dir names a folder for the second the invocation started and counts past any folder that
    # second already has, which is what keeps back-to-back runs apart. It only names the folder —
    # save_issue_frame creates it — so a run with nothing to report leaves the issues folder alone.
    P = Fromage.Paths
    d = mktempdir()
    a = P.invocation_issues_dir(d); mkpath(a)
    b = P.invocation_issues_dir(d); mkpath(b)
    c = P.invocation_issues_dir(d)
    @test allunique((a, b, c))
    @test all(==(d) ∘ dirname, (a, b, c))
    @test !ispath(c)
    # no colons in the stamp: these paths have to be creatable on Windows too
    @test !occursin(':', basename(a))
end

@testset "reference_space reports failures, and only the builder throws" begin
    # reference_space returns Union{ReferenceSpace, String}: every way a calibration can fail to
    # yield a shared reference is a fact about the user's file, so it is reported, not thrown.
    PT = Fromage.PawsomeTracker
    dir = mktempdir()
    vid, _, _, _ = make_apriltag_video(dir, "ref"; nframes = 20)
    file = joinpath(dir, vid)
    corrupt = make_corrupt_video(joinpath(dir, "corrupt.mp4"))

    @test PT.reference_space(file, 0.2, 4, "tag36h11", 8) isa PT.ReferenceSpace   # success
    @test PT.reference_space(file, 0.2, 99, "tag36h11", 8) isa String              # too few tags
    @test PT.reference_space(file, 0.2, 4, "tag99x9", 8) isa String              # unsupported family
    @test PT.reference_space(corrupt, 0.2, 4, "tag36h11", 8) isa String              # unreadable frame

    # the verification hook is now a plain type test, with no catch of its own
    @test PT.apriltag_extrinsic_issue(file, 0.2, 4, "tag36h11", 8) === nothing
    @test PT.apriltag_extrinsic_issue(file, 0.2, 99, "tag36h11", 8) isa String
    @test PT.apriltag_extrinsic_issue(corrupt, 0.2, 4, "tag36h11", 8) isa String

    # ...while the rectification builder, which has nowhere to put a message, still throws
    @test_throws ErrorException PT.ApriltagRectification(;
        aspect = 1.0, file = corrupt, extrinsic = 0.2, ntags = 4, family = "tag36h11",
        tag_cell_width = 8, center = missing, north = missing, width = 480, height = 480
    )
    @test_throws ErrorException PT.ApriltagRectification(;
        aspect = 1.0, file = file, extrinsic = 0.2, ntags = 99, family = "tag36h11",
        tag_cell_width = 8, center = missing, north = missing, width = 480, height = 480
    )
end

@testset "diagnostic video: multi-run, mixed calibrations" begin
    # All three rectification kinds in one pipeline run: two uniform rectifications on
    # different-sized source videos — the case the fixed canvas exists for, since a mixed-resolution
    # diagnostic cannot be stream-copied — plus a matlab rectification read from a .mat file.
    dir = mktempdir()
    make_video(joinpath(dir, "cal_big.mp4"); size = (640, 480))
    make_video(joinpath(dir, "cal_small.mp4"); size = (320, 240))
    # fronto-parallel pinhole; ImageSize [480, 640] matches cal_big.mp4 (the cross-check)
    matwrite(
        joinpath(dir, "cal.mat"), Dict(
            "cameraParams" => Dict(
                "ImageSize" => [480.0, 640.0],
                "K" => [500.0 0.0 320.0; 0.0 500.0 240.0; 0.0 0.0 1.0],
                "RotationVectors" => zeros(2, 3),
                "TranslationVectors" => [0.0 0.0 100.0; 0.0 0.0 200.0],
                "RadialDistortion" => [0.0, 0.0]
            )
        )
    )
    targets = [make_target_video(dir, "t$i") for i in 1:4]
    open(joinpath(dir, "rectifications.csv"), "w") do io
        println(io, "rectification_id,type,file,extrinsic,pixel_width,matlab_file,extrinsic_index")
        println(io, "c1,uniform,cal_big.mp4,1,1,,")
        println(io, "c2,uniform,cal_small.mp4,1,1,,")
        println(io, "m1,matlab,cal_big.mp4,1,,cal.mat,1")
    end
    calib_ids = ("c1", "c1", "c2", "m1")
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "run_id,rectification_id,file,start_location")
        for (i, (files, _)) in enumerate(targets)
            println(io, "run$i,$(calib_ids[i]),$(only(files)),\"(55, 50)\"")
        end
    end
    outdir = mktempdir()
    cd(() -> main(dir; tracking_defaults = (target_width = 10,)), outdir)
    # four runs, four track csvs — and no rectification images, which are off unless asked for, and
    # off means no trace at all: not even the folder
    @test count(endswith(".csv"), readdir(joinpath(outdir, "results_dir"))) == 4
    @test !ispath(joinpath(outdir, "results_dir", "rectifications"))
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

# The three concat testsets below all build one list out of real videos and read the joined result
# back, because the escaping is ffmpeg's rule and only real ffmpeg can say whether a name survived
# it. `stems` are file-name stems; the return is the file `concatenate` writes, always
# `diagnostic.mp4` in a fresh output folder. Each segment is 5 frames.
function concat_stems(stems)
    dir = mktempdir()
    segs = map(stems) do stem
        f = joinpath(dir, "$stem.mp4")
        make_video(f; duration = 1, size = (64, 64), rate = 5)
        f
    end
    results_dir = mktempdir()
    Fromage.concatenate(results_dir, dir, segs)
    return joinpath(results_dir, "diagnostic.mp4")
end

@testset "an apostrophe in a segment path survives the concat list" begin
    # ffmpeg takes each path in the concat list single-quoted, so an unescaped apostrophe closed the
    # line early and the segment after it was silently dropped. An apostrophe is a legal file-name
    # character and a plausible run_id ("beetle's run"), so it is escaped rather than rejected — and
    # asserted against real ffmpeg here, since the escaping is ffmpeg's rule and not ours to assume.
    joined = concat_stems(["beetle's run 1", "beetle's run 2"])
    @test isfile(joined)
    # both 5-frame segments, not just the one before the apostrophe broke the line
    @test probe_stream(joined).nframes == 10
end

@testset "every other legal file-name character survives the concat list too" begin
    # The apostrophe is not the only character that could have broken a line, and the rest are
    # escaped rather than rejected on the strength of this: backslashes and double quotes are
    # literal inside the quotes, spaces and control characters are preserved by them, non-ASCII
    # never mattered. One list holding all of them at once also asserts the entries stay separate —
    # a path that broke its line would take its neighbours' frames with it.
    #
    # Windows gets the shorter set: `\`, `"` and every control character are illegal in a file name
    # there (much the list the gateway rejects a `run_id` for), so there is no such path to assert
    # about. What is Windows-specific — drive-prefixed absolute paths, which the concat demuxer
    # accepts only under `-safe 0` — goes through the same list in the `main` testsets above.
    stems = Sys.iswindows() ? ["spa ce", "üñí çodé"] :
        ["back\\slash", "double\"quote", "spa ce", "tab\there", "bell\ahere", "üñí çodé"]
    joined = concat_stems(stems)
    @test isfile(joined)
    @test probe_stream(joined).nframes == 5 * length(stems)   # every segment, one entry each
end

@testset "a path the concat list cannot carry is refused by name" begin
    # The two characters the quoting cannot rescue: either one ends the list line whether or not it
    # sits inside the quotes, so the entry splits in two and ffmpeg reports the halves as junk
    # ("Line 2: unknown keyword"), naming neither the path nor the run it came from.
    dir = mktempdir()
    for bad in ("seg\nment.mp4", "seg\rment.mp4")
        @testset "path = $(repr(bad))" begin
            f = joinpath(dir, bad)
            e = (@test_throws ArgumentError Fromage.concatenate(mktempdir(), dir, [f])).value
            @test occursin(repr(f), e.msg)          # the offending path, in full
            @test occursin("concat list", e.msg)    # and the format that cannot hold it
        end
    end
end

# `verify` is the debugging entry point: report everything wrong with both files and hand them
# back, rather than stopping at the first one (#121). It replaced `main(strict = false)`, whose
# return type depended on whether the data happened to be clean.
@testset "verify reports both files instead of aborting" begin
    dir = mktempdir()
    make_video(joinpath(dir, "cal.mp4"); size = (320, 240), duration = 2)
    target, _ = make_target_video(dir, "nonstrict")
    open(joinpath(dir, "rectifications.csv"), "w") do io
        println(io, "rectification_id,type,file,extrinsic,pixel_width")
        println(io, "c1,uniform,cal.mp4,1,2")
        println(io, "c1,uniform,cal.mp4,1,2")     # duplicate id: a first-tier failure
    end
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "rectification_id,file,start_location")
        println(io, "c1,$(only(target)),\"(55, 50)\"")
    end
    outdir = mktempdir()

    @test_throws "there were issues" cd(() -> main(dir), outdir)      # the default still aborts

    # A dataset is accepted or rejected as a whole, so both tables come back annotated — handing
    # back built runs whose calibration was just rejected would imply a usability they lack (#122).
    out = cd(() -> verify(dir), outdir)
    @test out.rectifications isa DataFrame
    @test out.runs isa DataFrame
    @test hasproperty(out.rectifications, :issues)
    @test hasproperty(out.runs, :issues)
    @test any(!isempty, out.rectifications.issues)                            # the offending file
    @test all(isempty, out.runs.issues)                               # runs.csv itself was clean
end

# The two csv files must describe one dataset: every run's calibration exists, and every calibration
# is used (#122). Both are first-tier checks, so an incoherent pair costs no video reads at all.
@testset "rectifications.csv and runs.csv must be coherent" begin
    dir = mktempdir()
    make_video(joinpath(dir, "cal.mp4"); size = (320, 240), duration = 2)
    # seeded, like every other fixture: random bytes are unreadable whatever they are, but an
    # unseeded one cannot be reproduced from a failing log
    write(joinpath(dir, "broken.mp4"), rand(Xoshiro(20260901), UInt8, 4096))   # unreadable: probing it is loud
    target, _ = make_target_video(dir, "coh")
    outdir = mktempdir()

    @testset "a calibration no run uses is rejected, before anything is opened" begin
        write(
            joinpath(dir, "rectifications.csv"),
            "rectification_id,type,file,extrinsic,pixel_width\nc1,uniform,cal.mp4,1,2\nc2,uniform,broken.mp4,1,2\n"
        )
        write(
            joinpath(dir, "runs.csv"),
            "rectification_id,file,start_location\nc1,$(only(target)),\"(55, 50)\"\n"
        )
        _, out = capturing() do
            try
                cd(() -> main(dir; tracking_defaults = (target_width = 10,)), outdir)
            catch e
                e
            end
        end
        @test occursin("rectification_id c2 is not used by any row in runs.csv", out)
        # the unused calibration points at an unreadable video; probing it would say so loudly, so
        # this silence is what proves the first tier stopped before any read
        @test !occursin("issue reading from video file", out)
    end

    @testset "a run naming a calibration that does not exist is rejected, and both files reported" begin
        write(
            joinpath(dir, "rectifications.csv"),
            "rectification_id,type,file,extrinsic,pixel_width\nc1,uniform,cal.mp4,1,2\n"
        )
        write(
            joinpath(dir, "runs.csv"),
            "rectification_id,file,start_location\nc9,$(only(target)),\"(55, 50)\"\n"
        )
        _, out = capturing() do
            try
                cd(() -> main(dir; tracking_defaults = (target_width = 10,)), outdir)
            catch e
                e
            end
        end
        # both halves are reported in one pass: together they diagnose the typo
        @test occursin("rectification_id c9 is not defined in rectifications.csv", out)
        @test occursin("rectification_id c1 is not used by any row in runs.csv", out)
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
    write(
        joinpath(dir, "rectifications.csv"),
        "rectification_id,type,file,extrinsic,pixel_width\nc1,uniform,cal1.mp4,1,2\nc2,uniform,cal2.mp4,1,2\n"
    )
    # background_length = 0 on the tracked run rides along so `main` drives the no-subtraction path end
    # to end, csv → gateway → track; r2's blank cell takes the default
    write(
        joinpath(dir, "runs.csv"),
        "run_id,rectification_id,file,start_location,background_length\n" *
            "r1,c1,$(only(t1)),\"(55, 50)\",0\nr2,c2,$(only(t2)),\"(55, 50)\",\n"
    )
    outdir = mktempdir()

    cd(
        () -> main(
            dir; run_ids = ["r1"], tracking_defaults = (target_width = 10,),
            rectification_diagnostics = true
        ), outdir
    )
    results = joinpath(outdir, "results_dir")
    @test isfile(joinpath(results, "r1.csv"))           # the run asked for
    @test !isfile(joinpath(results, "r2.csv"))          # and not the other
    # only the calibration r1 needs was built: each built rectification saves its image, here through
    # the uniform builder, named by its rectification_id
    @test readdir(joinpath(results, "rectifications")) == ["c1.jpg"]
    @test filesize(joinpath(results, "rectifications", "c1.jpg")) > 0
end

# `results_dir` names the output folder itself, so where output goes no longer depends on the working
# directory (#229). None of these call `main` or `verify` inside a `cd`: that is the point.
@testset "results_dir: the caller names the output folder (#229)" begin
    dir = mktempdir()
    make_video(joinpath(dir, "cal.mp4"); size = (320, 240), duration = 2)
    target, _ = make_target_video(dir, "elsewhere")
    write(joinpath(dir, "rectifications.csv"), "rectification_id,type,file,extrinsic,pixel_width\nc1,uniform,cal.mp4,1,2\n")
    write(joinpath(dir, "runs.csv"), "run_id,rectification_id,file,start_location\nr1,c1,$(only(target)),\"(55, 50)\"\n")

    @testset "main writes everything under it, twice in one session" begin
        # Two analyses of one dataset kept side by side. The second call's track comes out of the
        # memo, and must still be written out in full into its own folder.
        first, second = (joinpath(mktempdir(), "exp", name) for name in ("a", "b"))   # neither exists yet
        for results_dir in (first, second)
            main(dir; tracking_defaults = (target_width = 10,), rectification_diagnostics = true, results_dir)
            @test readdir(results_dir; sort = true) == ["diagnostic.mp4", "r1.csv", "rectifications"]
            @test readdir(joinpath(results_dir, "rectifications")) == ["c1.jpg"]
            @test filesize(joinpath(results_dir, "diagnostic.mp4")) > 0
        end
        @test read(joinpath(first, "r1.csv"), String) == read(joinpath(second, "r1.csv"), String)
    end

    @testset "a clean verify creates nothing, the folder included" begin
        results_dir = joinpath(mktempdir(), "out")
        out = verify(dir; results_dir)
        @test all(isempty, out.rectifications.issues) && all(isempty, out.runs.issues)
        @test !ispath(results_dir)
    end

    # A failing AprilTag detection is what dumps an issue frame.
    tagdir = mktempdir()
    vid, _, _, _ = make_apriltag_video(tagdir, "drone")
    write(joinpath(tagdir, "rectifications.csv"), "rectification_id,type,file,extrinsic,apriltags,family,tag_cell_width\ndrone,apriltag,$vid,0,6,tag36h11,12\n")
    write(joinpath(tagdir, "runs.csv"), "rectification_id,file,start_location\ndrone,$vid,\"(55, 50)\"\n")
    saved_frame(out) = only(
        m.captures[1] for m in (match(r" to (.+\.png) for inspection$", msg) for msg in only(out.rectifications.issues))
            if !isnothing(m)
    )

    @testset "verify puts its issue frames under it" begin
        results_dir = joinpath(mktempdir(), "out")
        frame = saved_frame(verify(tagdir; results_dir))
        @test isfile(frame)
        @test dirname(dirname(frame)) == joinpath(results_dir, "issues")   # issues/<stamp>/<frame>.png
    end

    # Changing the working directory part-way through a call cannot be staged from outside it, so this
    # asserts what makes that safe instead: a relative `results_dir` is resolved once, on entry, so the
    # path the report names is already absolute, against the directory the call was made from.
    @testset "a relative results_dir resolves against the working directory at the call" begin
        cwd = mktempdir()
        frame = cd(() -> saved_frame(verify(tagdir; results_dir = "rel")), cwd)
        @test isabspath(frame)
        @test startswith(frame, joinpath(cd(pwd, cwd), "rel", "issues"))
        @test isfile(frame)
    end
end

end
