# The two columns the whole-run tracker adds, `whole_run` and `arena_radius`, as the gateway sees
# them. Everything here also pins the other half of the contract: a row that does not opt in is
# verified exactly as before, whatever the new columns hold.
#
# Its own header, so the rest of the suite's scenarios keep writing the csv they always wrote.
const WHOLE_HEADER = [HEADER; "whole_run"; "arena_radius"]
wholerow(; kw...) = buildrow(WHOLE_HEADER; merge((run_id = "r", rectification_id = "c", file = ART.a), values(kw))...)
checkwhole(rows; kw...) = check(rows; header = WHOLE_HEADER, kw...)
function loaded_whole(rows)
    runs = checkwhole(rows)
    @test clean(runs)
    return only(runs)
end

@testset "the whole-run columns" begin
    @testset "a row that does not opt in keeps today's defaults" begin
        t = only(checkwhole([wholerow()])).tuning
        @test t.whole_run == false
        @test ismissing(t.arena_radius)
        @test t.downscale == 1.0
        @test t.sample_fps == 30.0          # a.mp4's own rate, through native_fps as before
        # and so does one that says so
        @test only(checkwhole([wholerow(whole_run = "false")])).tuning.downscale == 1.0
    end

    @testset "a whole-run row's blank downscale and sample_fps are /3 and 5 Hz" begin
        t = only(checkwhole([wholerow(whole_run = "true")])).tuning
        @test t.whole_run == true
        @test t.downscale == 1 / 3
        @test t.sample_fps == 5.0
        @test t.native_fps == 30.0          # untouched: it is the video's own rate
    end

    @testset "a cell or a caller's default still wins on a whole-run row" begin
        t = only(checkwhole([wholerow(whole_run = "true", downscale = "0.5", sample_fps = "10")])).tuning
        @test (t.downscale, t.sample_fps) == (0.5, 10.0)
        t = only(checkwhole([wholerow(whole_run = "true")]; defaults = (downscale = 0.5, sample_fps = 10))).tuning
        @test (t.downscale, t.sample_fps) == (0.5, 10.0)
        # even when what the caller passed equals the online tracker's hardcoded default
        t = only(checkwhole([wholerow(whole_run = "true")]; defaults = (downscale = 1.0,))).tuning
        @test (t.downscale, t.sample_fps) == (1.0, 5.0)
    end

    @testset "whole_run and arena_radius are settable globally" begin
        t = only(checkwhole([wholerow()]; defaults = (whole_run = true, arena_radius = 500))).tuning
        @test t.whole_run == true
        @test t.arena_radius == 500.0
        @test (t.downscale, t.sample_fps) == (1 / 3, 5.0)
        # a cell still wins over the global default
        @test only(checkwhole([wholerow(whole_run = "false")]; defaults = (whole_run = true,))).tuning.whole_run == false
    end

    @testset "arena_radius" begin
        @test only(checkwhole([wholerow(whole_run = "true", arena_radius = "480.5")])).tuning.arena_radius == 480.5
        msg = "arena_radius must be larger than zero"
        @test flagged(checkwhole([wholerow(whole_run = "true", arena_radius = "0")]), 1, msg)
        @test flagged(checkwhole([wholerow(whole_run = "true", arena_radius = "-5")]), 1, msg)
        # ignored, not reported, on a row that does not opt in: the gateway has no irrelevant-column
        # check, and a row that does not opt in must verify exactly as it did before the column
        @test clean(checkwhole([wholerow(arena_radius = "-5")]))
        @test flagged(checkwhole([wholerow(arena_radius = "wide")]), 1, "wrong arena_radius format")
    end

    @testset "a malformed whole_run is reported" begin
        @test flagged(checkwhole([wholerow(whole_run = "sometimes")]), 1, "wrong whole_run format")
    end

    @testset "the seam: a whole-run row goes to the whole-run tracker, any other to the online one" begin
        files, _ = make_target_video("seam_whole"; width = 100, height = 100, target_width = 20, noise = 10)
        rows(w) = [wholerow(file = only(files), target_width = "20", start_location = "(55, 50)", whole_run = w)]
        ts, _ = VR.track(loaded_whole(rows("true")), missing, nothing, nothing)
        @test step(ts) ≈ 1 / 5       # the whole-run grid's 5 Hz
        ts, _ = VR.track(loaded_whole(rows("false")), missing, nothing, nothing)
        @test step(ts) ≈ 1 / 25      # the video's own rate, as before
    end

    @testset "a blank start_location is searched for within initial_search_factor's window (#397)" begin
        # The whole-run path's first sample lies within a radius of its anchor. A searched-for start
        # gets the online tracker's initial search radius, min(width, height) / 2initial_search_factor
        # — 50 px at factor 2, 12.5 at factor 8 — around the frame centre (100, 100), and the target
        # starts 45 px right of it. It used to get half a tracking window (20 px here) at any factor,
        # and `refine` cannot carry a path from there to a target that far out.
        files, expected = make_target_video("s397_whole"; width = 200, height = 200, target_width = 20, row = 100, col = 145, noise = 10)
        first_point(factor) = first(VR.track(loaded_whole([wholerow(file = only(files), target_width = "20", whole_run = "true", initial_search_factor = factor)]), missing, nothing, nothing)[2])
        on_target(p) = hypot((p .- expected(1))...) < 5     # a third-resolution grid: 3 px a cell
        @test on_target(first_point("2"))
        @test !on_target(first_point("8"))
    end

    @testset "both are run-level: a run's segments must agree on them" begin
        # the blank downscale and sample_fps each segment fell back to disagree with it, so the
        # report names them too; what matters is that whole_run is among them
        rows = [wholerow(whole_run = "true"), wholerow(whole_run = "false", file = ART.b)]
        df = checkwhole(rows)
        @test df isa DataFrame
        @test any(m -> startswith(m, "run segments disagree on") && occursin("whole_run", m), df.issues[1])
        rows = [
            wholerow(whole_run = "true", arena_radius = "500"),
            wholerow(whole_run = "true", arena_radius = "400", file = ART.b),
        ]
        @test flagged(checkwhole(rows), 1, "run segments disagree on arena_radius")
    end
end
