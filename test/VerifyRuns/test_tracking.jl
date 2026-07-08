# Tracking accuracy through the gateway: CSV → load_runs → VR.track on synthetic videos with a
# known trajectory (make_target_video), asserting the RMSE (stored-frame pixels) against the
# closed-form ground truth. Covers the combinations VerifyRuns can hand PawsomeTracker: the
# start_location sources (CSV cell, rectification `center`, frame-center default), the window_size
# sources (imputed, CSV scalar, CSV (w, h) tuple), darker/lighter targets, reduced fps, a start/stop
# sub-window, downscaling, segmented runs — and anamorphic videos (sar ≠ 1), where inputs
# (start_location, center, frame center) are display-space and outputs are stored-space.
@testset "tracking through the gateway" begin
    base,  base_exp  = make_target_video("t_base")
    light, light_exp = make_target_video("t_light"; darker_target = false)
    sar05, sar05_exp = make_target_video("t_sar05"; sar = 1//2)
    sar2,  sar2_exp  = make_target_video("t_sar2";  sar = 2//1)
    seg,   seg_exp   = make_target_video("t_seg";  nsegments = 3)
    seg2,  seg2_exp  = make_target_video("t_seg2"; sar = 2//1, nsegments = 3)

    @testset "defaults: imputed stop/fps/window, frame-center start" begin
        runs = check("t_base.csv", [runrow(file = only(base))])
        @test clean(runs)
        _, ij = VR.track(only(runs))
        @test length(ij) == 50                       # stop imputed from the full 2 s at 25 fps
        @test tracking_rmse(ij, base_exp) < 1
    end

    @testset "start_location sources" begin
        # explicit CSV cell
        runs = check("t_sl_csv.csv", [runrow(file = only(base), start_location = "(55, 50)")])
        @test clean(runs)
        _, ij = VR.track(only(runs))
        @test tracking_rmse(ij, base_exp) < 1
        # the `center` keyword (what Fromage passes from the rectification)
        runs = check("t_sl_ctr.csv", [runrow(file = only(base))])
        @test clean(runs)
        _, ij = VR.track(only(runs); center = (55, 50))
        @test tracking_rmse(ij, base_exp) < 1
    end

    @testset "window_size sources" begin
        runs = check("t_win_i.csv", [runrow(file = only(base), window_size = "31")])
        @test clean(runs)
        _, ij = VR.track(only(runs))
        @test tracking_rmse(ij, base_exp) < 1
        runs = check("t_win_t.csv", [runrow(file = only(base), window_size = "(31, 21)")])
        @test clean(runs)
        _, ij = VR.track(only(runs))
        @test tracking_rmse(ij, base_exp) < 1
    end

    @testset "lighter target on dark background" begin
        runs = check("t_light.csv", [runrow(file = only(light), darker_target = "false")])
        @test clean(runs)
        _, ij = VR.track(only(runs))
        @test tracking_rmse(ij, light_exp) < 1
    end

    @testset "requested fps below the video's rate" begin
        runs = check("t_fps.csv", [runrow(file = only(base), fps = "12.5")])
        @test clean(runs)
        _, ij = VR.track(only(runs))
        @test length(ij) == 25                       # every other frame
        @test tracking_rmse(ij, base_exp; skip = 2) < 1
    end

    @testset "start/stop sub-window" begin
        # the start_location must be where the target is at t = start (frame 10), not at t = 0
        runs = check("t_sub.csv", [runrow(file = only(base), start = "0.4", stop = "1.6", start_location = "(32, 50)")])
        @test clean(runs)
        _, ij = VR.track(only(runs))
        @test length(ij) == 30
        @test tracking_rmse(ij, base_exp; offset = 10) < 1
    end

    @testset "downscaled tracking (scale = 0.5)" begin
        # coordinates come back in the *original* stored-frame pixels regardless of scale
        runs = check("t_scale.csv", [runrow(file = only(base), scale = "0.5")])
        @test clean(runs)
        _, ij = VR.track(only(runs))
        @test tracking_rmse(ij, base_exp) < 1
    end

    @testset "anamorphic (sar ≠ 1)" begin
        for (slug, label, files, exp) in (("sar05", "sar 1/2 (stored 200×100)", sar05, sar05_exp),
                                          ("sar2",  "sar 2 (stored 50×100)",    sar2,  sar2_exp))
            @testset "$label" begin
                # explicit display-space start_location; for sar 2 its x (55) exceeds the *stored*
                # width (50) — valid, because bounds are display-space (width × sar)
                runs = check("t_$slug.csv", [runrow(file = only(files), start_location = "(55, 50)")])
                @test clean(runs)
                _, ij = VR.track(only(runs))
                @test tracking_rmse(ij, exp) < 1
                # frame-center default must be the *display* center, sar-corrected
                runs = check("t_$(slug)_c.csv", [runrow(file = only(files))])
                @test clean(runs)
                _, ij = VR.track(only(runs))
                @test tracking_rmse(ij, exp) < 1
            end
        end
        # display-space bounds, both directions: the sar-1/2 video stores 200×100 but displays
        # 100×100, so x = 150 is out; the sar-2 video stores 50×100 but displays 100×100, so x = 80 is in
        @test flagged(check("t_sar_oob.csv", [runrow(file = only(sar05), start_location = "(150, 50)")]), 1, "start_location is outside the frame")
        @test clean(check("t_sar_inb.csv",   [runrow(file = only(sar2),  start_location = "(80, 50)")]))
        # anamorphic and downscaled at once
        runs = check("t_sar_sc.csv", [runrow(file = only(sar2), start_location = "(55, 50)", scale = "0.5")])
        @test clean(runs)
        _, ij = VR.track(only(runs))
        @test tracking_rmse(ij, sar2_exp) < 1
    end

    @testset "segmented runs" begin
        # rows share a run_id; only the first segment gets a start_location, the rest continue
        # from where the previous segment ended (keyframe-aligned 17 + 17 + 16 frames)
        rows = [runrow(run_id = "s", file = f, start_location = i == 1 ? "(55, 50)" : missing)
                for (i, f) in enumerate(seg)]
        runs = check("t_seg.csv", rows)
        @test clean(runs)
        r = only(runs)
        @test r isa VR.MultiRun
        _, ij = VR.track(r)
        @test length(ij) == 50
        @test tracking_rmse(ij, seg_exp) < 1
        # anamorphic segmented run, frame-center start
        runs = check("t_seg2.csv", [runrow(run_id = "s2", file = f) for f in seg2])
        @test clean(runs)
        _, ij = VR.track(only(runs))
        @test tracking_rmse(ij, seg2_exp) < 1.5
    end
end
