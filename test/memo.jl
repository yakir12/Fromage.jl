# The memo behind the iterate-on-your-csv workflow (#233, #251, #249): a Julia process remembers every
# read, every detection, every rectification it has BUILT and every run it has TRACKED, so a second
# `main`/`verify` over an unchanged dataset spawns no ffprobe, reads no `.mat`, detects nothing, builds
# nothing and tracks nothing.
#
# Two things are asserted here, and the second is the one that matters. That the caches HIT is a
# performance claim, and it is asserted on the hit/miss counters rather than on wall-clock time,
# which on this machine is noise (DECISIONS). That every parameter a memoized computation reads is
# part of its key is a CORRECTNESS claim: an under-specified key is the one way this change can
# return a wrong answer rather than merely a slow one, so each parameter is varied on its own and
# the recomputation asserted, rather than reasoned about from the source. The build's and the track's
# arguments are whole OBJECTS, so for those the same claim is made structurally over `fieldnames` —
# see `variants` below.
#
# Path-keyed caching is safe across the suite only because every fixture path is written exactly
# once, with one content, for the life of the test process: the shared artifact blocks in both
# gateway helpers run once at const-initialisation, and every generated fixture gets a distinct,
# suite-prefixed name. A test that needs differently-encoded content must use a NEW fixture name —
# rewriting an existing path would serve it the cached read of the old one.
module MemoTests

using Test
using Fromage: Fromage
using LRUCache: LRU, haskey
using MAT: MAT
using ..Fixtures

const M = Fromage.Memo
const VRect = Fromage.VerifyRectifications
const VRuns = Fromage.VerifyRuns
const PT = Fromage.PawsomeTracker

# Every cache the VERIFICATION half fills. The build and track caches (#251, #249) are left out
# because the two `check_*` functions build and track nothing, so they would never move with the
# others; derived from `M.CACHES` by exclusion rather than listed, so a verification cache added later
# is counted here without this line being touched.
const VERIFICATION_CACHES = filter(c -> !any(x -> x === c, (M.BUILT_RECTIFICATIONS, M.TRACKED_RUNS)), M.CACHES)

# What every verification cache has computed so far, by identity. The counters are process-global
# and other suites share them, so every assertion below is on a DELTA taken around one call.
snapshot(caches = VERIFICATION_CACHES) = map(M.misses, caches), map(M.hits, caches)

# A failing extrinsic detection appends the path it dumped the frame to, and that path names the
# INVOCATION's own folder — so two verifications of one failing dataset must agree on the verdict
# and differ on the path. These two split a report into those halves.
# The note names the video and extrinsic before the path (#155), so the path is what follows " s to ".
const SAVED_TAIL = " — saved the extrinsic frame of "
const SAVED_PATH = r" s to (.+\.png) for inspection$"
verdicts(df) = [[first(split(m, SAVED_TAIL)) for m in msgs] for msgs in skipmissing(df.issues)]
saved_frames(df) = [
    String(only(match(SAVED_PATH, m).captures))
        for msgs in skipmissing(df.issues) for m in msgs if occursin(SAVED_TAIL, m)
]

const CHECKERBOARD_PNG = joinpath(@__DIR__, "VerifyRectifications", "fixtures", "checkerboard.png")

# A structurally complete MATLAB calibration, shaped like the gateway suite's: the reader wants
# ImageSize plus the four fields the builder needs. ImageSize is [height, width], and must match the
# source video or the cross-check flags the row.
function make_mat(path, (width, height))
    MAT.matwrite(
        path, Dict(
            "ImageSize" => [Float64(height), Float64(width)],
            "TranslationVectors" => zeros(6, 3), "RotationVectors" => zeros(6, 3),
            "RadialDistortion" => [0.0, 0.0], "K" => [1.0 0.0 0.0; 0.0 1.0 0.0; 0.0 0.0 1.0],
        )
    )
    return path
end

# Every fixture this suite owns, written once into a directory of its own and never rewritten — the
# invariant the header states, kept here by construction.
const DIR = mktempdir()
const BOARD = make_checkerboard_video(joinpath(DIR, "memo_board.mp4"), CHECKERBOARD_PNG; duration = 2)
const PLAIN = make_video(joinpath(DIR, "memo_plain.mp4"); duration = 2, size = (320, 240), rate = 25)
const OTHER = make_video(joinpath(DIR, "memo_other.mp4"); duration = 2, size = (320, 240), rate = 25)
const MAT1 = make_mat(joinpath(DIR, "memo_one.mat"), (320, 240))
const MAT2 = make_mat(joinpath(DIR, "memo_two.mat"), (320, 240))

# A verified rectifications row of each of the four kinds, constructed directly rather than parsed:
# what this suite is about is the KEY, and the parser has its own tests. `center`/`north` are filled
# rather than left blank so that varying them below is a change of value and not of type.
src(file = PLAIN) = VRect.Source(file, 1.0, (10, 20), (30, 40), 1.0, 320, 240)

# A different value of the same shape for every field type these structs are built from, so a
# one-field variant can be derived from `fieldnames` rather than from a hand-written list per kind —
# a field added to one of them later is then covered without this file being edited.
vary(x::Bool) = !x
vary(x::Int) = x + 1
vary(x::Float64) = x + 1.0
vary(x::String) = string(x, "-other")
vary(x::NTuple{2, Int}) = (x[1] + 1, x[2])
vary(x::Rational{Int}) = x + 1

# Rebuild `x` with field `i` replaced. Reaching the constructor by NAME drops the type parameter, so
# a `Checkerboard{Float64}` is rebuilt by its own constructor rather than pinned by this function;
# for the non-parametric types it is the type itself. `typeof(x).name.wrapper` does the same
# thing in one expression and is what this was first written as — but `TypeName.wrapper` is a Base
# internal, and there is nothing internal about asking a module for a type it exports.
function replace_field(x, i, v)
    T = typeof(x)
    constructor = getfield(parentmodule(T), nameof(T))
    return constructor(ntuple(j -> j == i ? v : getfield(x, j), fieldcount(T))...)
end

# The structs a key is built from that are themselves built from fields, and are varied field by
# field rather than as one value: a rectification's `Source`, and a run's tuning, frame format and
# segments. Those nested fields are part of the key just as much as the outer ones, and are where an
# under-specified key would hurt most — `center` and `north` change the map without changing anything
# else about the row, and a segment's `stop` changes the track without changing the run's id.
const NESTED = Union{VRect.Source, PT.Tuning, PT.Segment, VRuns.FrameFormat}
field_variants(f, name) = [name => vary(f)]
field_variants(f::NESTED, name) = variants(f, name)
# A run's segments: every field of the first one, and one segment more.
field_variants(f::Vector{PT.Segment}, name) = [
    [n => [v; f[2:end]] for (n, v) in field_variants(first(f), string(name, "[1]"))];
    string(name, " (one segment more)") => [f; f]
]

# Every one-field variant of `x`, recursing into the `NESTED` fields.
function variants(x, name = string(nameof(typeof(x))))
    # Every variant is still the same concrete type as `x` — varying one field never leaves its
    # declared type, `Checkerboard{Float64}`'s two `::S` bounds included — so the eltype says so.
    T = typeof(x)
    vs = Pair{String, T}[]
    for i in 1:fieldcount(T), (n, v) in field_variants(getfield(x, i), string(name, ".", fieldname(T, i)))
        push!(vs, n => replace_field(x, i, v))
    end
    return vs
end

# The board video's own frame size — the checkerboard png padded to even dimensions. Read off the
# file rather than hard-coded, since the detectors are keyed on it and a wrong value would silently
# turn every detection into a reshape failure instead of a detection.
const BOARD_W, BOARD_H = let f = Fromage.Probing.probe_fields(BOARD, "stream=width,height")
    parse(Int, f["width"]), parse(Int, f["height"])
end

# Both build testsets drive the real build: the rectifications gateway's loader, then
# `build_rectifications`, the function `main` builds through — without a run to track. Both write
# under an output folder (a failing detection's frame, a diagnostic image), so each gets a scratch
# directory of its own rather than whatever the suite was started from. Returns
# that directory (the diagnostic testset needs it to find the image) and a closure performing one
# invocation. The csv itself stays at the call sites: what the two write differs, and this is the
# only part of the shape that was the same.
function rectifier(csv; rectification_diagnostics = false)
    outdir = mktempdir()
    rectify() = Fromage.build_rectifications(
        outdir,
        VRect.load_rectifications(dirname(csv), csv; defaults = (;), results_dir = outdir, progress = true),
        rectification_diagnostics
    )
    return outdir, rectify
end

# One of each kind of rectifications row, for the structural key testset. `Checkerboard` is the
# parametric one, and this is its `{Float64}` instance — the blank-window `{Missing}` form differs in
# the type of two fields, so it is a different key by construction and needs no row of its own.
const METHODS = (
    VRect.Uniform(src(), "u", 2.0),
    VRect.Checkerboard(src(BOARD), "c", 0.0, 1.0, 4.0, (5, 8), 0.5, 1, 0.0, false),
    VRect.Apriltag(src(), "a", 4, "tag36h11", 12.0),
    VRect.MATLAB(src(), "m", MAT1, 1),
)

# The tracking half (#249). Two trackable videos — the shared known-trajectory disc, 100×100, 2 s at
# 25 fps — and one that `track` cannot read. `RUN` is a verified run constructed directly, like
# `METHODS`, for the tests about the key; the end-to-end testsets go through `main` and its csv.
target(name) = joinpath(DIR, only(first(make_target_video(DIR, name))))
const TARGET1 = target("memo_target1")
const TARGET2 = target("memo_target2")
const UNTRACKABLE = make_corrupt_video(joinpath(DIR, "memo_untrackable.mp4"))
const RUN = VRuns.Run(
    "memo_run", "u", tuning(TARGET1; target_width = 10.0), VRuns.FrameFormat(100, 100, 1 // 1),
    [PT.Segment(TARGET1, 0.0, 1.0, (55, 50))]
)

# Each memoized computation, its cache, and an alternative value for EVERY one of its arguments.
# Varying one at a time must recompute: if any parameter is absent from the key, its row here fails.
# The alternatives differ by VALUE — `0` and `0.0` are the same key, and rightly so, since they are
# the same question of the same frame.
const MEMOIZED = (
    (
        name = "probe_fields", cache = M.VIDEO_PROBES, f = Fromage.Probing.probe_fields,
        base = (PLAIN, "stream=width,height"),
        alts = (OTHER, "stream=width,height,duration"),
    ),
    (
        name = "matlab_metadata", cache = M.MATLAB_METADATA, f = VRect.matlab_metadata,
        base = (MAT1,), alts = (MAT2,),
    ),
    (
        name = "extrinsic_issue", cache = M.EXTRINSIC_DETECTIONS, f = VRect.extrinsic_issue,
        #      file,  extrinsic, yadif, blur, width,   height,  n_corners
        base = (BOARD, 1.0, false, 0.0, BOARD_W, BOARD_H, (5, 8)),
        alts = (PLAIN, 1.5, true, 2.0, BOARD_W - 2, BOARD_H - 2, (6, 9)),
    ),
    (
        name = "intrinsic_issue", cache = M.INTRINSIC_DETECTIONS, f = VRect.intrinsic_issue,
        #      file,  start, stop, step, yadif, blur, width,   height,  n_corners
        base = (BOARD, 0.0, 1.0, 0.5, false, 0.0, BOARD_W, BOARD_H, (5, 8)),
        alts = (PLAIN, 0.5, 1.5, 0.25, true, 2.0, BOARD_W - 2, BOARD_H - 2, (6, 9)),
    ),
    (
        name = "apriltag_extrinsic_issue", cache = M.APRILTAG_DETECTIONS,
        f = PT.apriltag_extrinsic_issue,
        #      file,  extrinsic, ntags, family, tag_cell_width
        base = (PLAIN, 1.0, 4, "tag36h11", 12),
        alts = (OTHER, 1.5, 3, "tag25h9", 13),
    ),
    # The build (#251). Its argument list is ONE object, so the varied-parameter testset says only
    # that the object is the key; that every FIELD of it is part of that key is the structural
    # testset below. A `uniform` row because it is the one kind that reads nothing at all to build,
    # which also makes it the cheap way this row primes the cache for `empty_caches!`.
    (
        name = "build_rectification", cache = M.BUILT_RECTIFICATIONS,
        f = Fromage.build_rectification,
        base = (METHODS[1],), alts = (VRect.Uniform(src(), "u-alt", 3.0),),
    ),
    # Tracking (#249). Like the build, each argument is a whole object; that every field of the run
    # and of the rectification method is part of the key is the structural testset below.
    (
        name = "track_run", cache = M.TRACKED_RUNS, f = Fromage.track_run,
        base = (RUN, METHODS[1]),
        alts = (replace_field(RUN, 1, "memo_run-alt"), VRect.Uniform(src(), "u-alt", 3.0)),
    ),
)

@testset "Memo (a session remembers what it read and what it built)" begin

    @testset "a second verification of the same dataset reads and detects nothing" begin
        csv = joinpath(DIR, "rectifications.csv")
        open(csv, "w") do io
            println(io, "rectification_id,path,file,matlab_file,type,extrinsic,extrinsic_index,intrinsic_start,intrinsic_stop,n_corners,checker_width,temporal_step,radial_parameters,blur,apriltags,family,tag_cell_width")
            println(io, "board,.,memo_board.mp4,,checkerboard,00:00:01,,00:00:00,00:00:01,\"(5, 8)\",4,0.5,1,0,,,")
            println(io, "mat,.,memo_plain.mp4,memo_one.mat,matlab,00:00:01,1,,,,,,,,,,")
            println(io, "tags,.,memo_other.mp4,,apriltag,00:00:01,,,,,,,,,4,tag36h11,12")
        end
        runs_csv = joinpath(DIR, "runs.csv")
        open(runs_csv, "w") do io
            println(io, "run_id,rectification_id,path,file,start,stop")
            println(io, "r1,board,.,memo_plain.mp4,00:00:00,00:00:01")
        end

        # One output folder for both passes, so the per-invocation folders land side by side and can
        # be told apart.
        idir = mktempdir()
        check_rects() = VRect.check_rectifications(DIR, csv; defaults = (;), results_dir = idir, progress = true)
        check_runs() = VRuns.check_runs(DIR, runs_csv; defaults = (;), progress = true)

        # First pass: everything is read and detected for the first time, so every cache misses.
        before = snapshot()
        first_rects, first_runs = check_rects(), check_runs()
        after = snapshot()
        @test all(after[1] .> before[1])                       # every one of the five caches computed something

        # Second pass, same files, same rows: nothing is recomputed and everything is served.
        second_rects, second_runs = check_rects(), check_runs()
        again = snapshot()
        @test again[1] == after[1]                             # no new misses: no ffprobe, no matread, no detection
        @test all(again[2] .> after[2])                        # every cache served instead

        # ...and says exactly the same thing, which is the point of the whole exercise.
        @test verdicts(second_rects) == verdicts(first_rects)
        @test verdicts(second_runs) == verdicts(first_runs)

        # The one part of a failing verification that is NOT memoized: the frame dump. The detector's
        # verdict is served from the cache, but every invocation still saves the frame it describes
        # into its own folder and names its own path in the message (#86) — which is what a user
        # re-running to look at the failure depends on.
        @test length(saved_frames(first_rects)) == 1 && length(saved_frames(second_rects)) == 1
        @test saved_frames(first_rects) != saved_frames(second_rects)
        @test all(isfile, [saved_frames(first_rects); saved_frames(second_rects)])
        @test dirname(only(saved_frames(first_rects))) != dirname(only(saved_frames(second_rects)))
        @test all(==(joinpath(idir, "issues")) ∘ dirname ∘ dirname, [saved_frames(first_rects); saved_frames(second_rects)])

        # After `empty_caches!` the same dataset is read from scratch again, with the same verdict.
        Fromage.empty_caches!()
        third_rects, third_runs = check_rects(), check_runs()
        @test all(map(M.misses, VERIFICATION_CACHES) .> 0)     # counters reset by empty!, so this is the fresh count
        @test verdicts(third_rects) == verdicts(first_rects)
        @test verdicts(third_runs) == verdicts(first_runs)
    end

    @testset "every parameter of $(m.name) is part of its key" for m in MEMOIZED
        # From empty, so the count below is exact and no entry another testset happened to compute
        # can be mistaken for this one's.
        Fromage.empty_caches!()
        m.f(m.base...)                                  # prime, so the baseline is certainly cached
        for i in eachindex(m.base)
            args = ntuple(j -> j == i ? m.alts[j] : m.base[j], length(m.base))
            hits = M.hits(m.cache)
            m.f(args...)
            # The claim is exactly "this was not answered out of the cache", so it is asserted on
            # the HIT counter. Misses would be the obvious choice and are the wrong one: some of
            # these alternatives cannot be read at all (a frame size that does not match the file),
            # and a failed read is deliberately not stored — so it is not counted as a miss either,
            # while still being unmistakably a recomputation.
            @test M.hits(m.cache) == hits
        end
        # the baseline is still there, and still served
        hits = M.hits(m.cache)
        m.f(m.base...)
        @test M.hits(m.cache) == hits + 1
    end

    # The build memo (#251). `rectifier` is the cheapest way to run the real `build_rectifications`,
    # and that function is the single definition site `main` builds through too — so what is asserted
    # here holds for `main` without tracking a run to find out.
    #
    # `uniform` rows because that is the one kind whose builder reads nothing: what is under test is
    # the cache, and a checkerboard would spend the suite's time on corner detection to say the same
    # thing. Verification still probes both videos, which is what makes these rows realistic rather
    # than synthetic.
    @testset "a second build of the same rectifications builds nothing" begin
        csv = joinpath(DIR, "memo_uniform.csv")
        # The csv is rewritten between passes, which the header's write-once rule does not cover and
        # does not need to: csv TEXT is never memoized, only the videos it names — and those two are
        # written once, like every other fixture here.
        write_rows(second_pixel_width) = open(csv, "w") do io
            println(io, "rectification_id,path,file,type,extrinsic,pixel_width")
            println(io, "u1,.,memo_plain.mp4,uniform,00:00:01,2")
            println(io, "u2,.,memo_other.mp4,uniform,00:00:01,$second_pixel_width")
        end
        _, rectify = rectifier(csv)

        write_rows(3)
        Fromage.empty_caches!()
        first_built = rectify()
        @test M.misses(M.BUILT_RECTIFICATIONS) == 2            # both built, from cold
        @test M.hits(M.BUILT_RECTIFICATIONS) == 0

        second_built = rectify()
        @test M.misses(M.BUILT_RECTIFICATIONS) == 2            # neither rebuilt
        @test M.hits(M.BUILT_RECTIFICATIONS) == 2              # both served
        # The SAME rectification, not an equal one — a hit hands the previous invocation's object
        # back. Nothing in `src/` is a mutable struct, which is what makes that sharing safe.
        @test all(map(===, first_built, second_built))

        # One row edited: that rectification is rebuilt, and the row the user did not touch is not.
        # This is the whole point of the feature — the user's edit was to one row, not to the folder.
        write_rows(4)
        third_built = rectify()
        @test M.misses(M.BUILT_RECTIFICATIONS) == 3            # exactly one rebuild
        @test M.hits(M.BUILT_RECTIFICATIONS) == 3              # ...and the untouched row served again
        @test third_built[1] === first_built[1]
        @test third_built[2] !== first_built[2]
    end

    # `main` says it too, and the spec asked for it by name (#251). `rectifier` above shares
    # `build_rectifications` with `main`, so this could be argued rather than run — but the claim a
    # user actually reads is about `main`, and the whole feature is worth one end-to-end pass.
    @testset "a second `main` over an unchanged dataset builds nothing" begin
        csv = joinpath(DIR, "memo_main.csv")
        open(csv, "w") do io
            println(io, "rectification_id,path,file,type,extrinsic,pixel_width")
            println(io, "m1,.,memo_plain.mp4,uniform,00:00:01,2")
        end
        runs_csv = joinpath(DIR, "memo_main_runs.csv")
        open(runs_csv, "w") do io
            println(io, "run_id,rectification_id,path,file,start,stop")
            println(io, "mr1,m1,.,memo_plain.mp4,00:00:00,00:00:01")
        end
        outdir = mktempdir()
        go() = cd(
            () -> Fromage.main(
                DIR; rectifications_file = basename(csv), runs_file = basename(runs_csv)
            ), outdir
        )

        # That a hit serves the SAME object is asserted on `rectifier` above; `main` returns nothing
        # (#256), so there is no object here to compare, and the counters are the whole claim.
        #
        # Hits are counted as deltas because tracking asks the build cache too: `track_run` fetches
        # the rectification it tracks through from there, and only when the track itself was not
        # cached — so the cold invocation serves one, and the warm one, whose track is cached, none.
        Fromage.empty_caches!()
        go()
        @test M.misses(M.BUILT_RECTIFICATIONS) == 1
        hits = M.hits(M.BUILT_RECTIFICATIONS)

        go()
        @test M.misses(M.BUILT_RECTIFICATIONS) == 1                # nothing rebuilt
        @test M.hits(M.BUILT_RECTIFICATIONS) == hits + 1           # served instead
    end

    # The blank-window `Checkerboard{Missing}` is a different TYPE from the filled `{Float64}`, so it
    # is a different key with no field varying at all. It is not in `METHODS` because `variants`
    # cannot produce it: `intrinsic_start`/`intrinsic_stop` are both `::S`, so varying one alone is
    # not constructible — which is the same fact from the other side, and is why this is asserted
    # here rather than folded into the structural testset.
    @testset "a blank intrinsic window is a different key from a filled one" begin
        blank = VRect.Checkerboard(src(BOARD), "c", missing, missing, 4.0, (5, 8), 0.5, 1, 0.0, false)
        Fromage.empty_caches!()
        get!(() -> nothing, M.BUILT_RECTIFICATIONS, METHODS[2])
        @test haskey(M.BUILT_RECTIFICATIONS, METHODS[2])
        @test !haskey(M.BUILT_RECTIFICATIONS, blank)
    end

    # The correctness half, and the reason this is more than a speed-up: the key IS the object, so a
    # field that did not participate in hashing would serve one row's rectification for another's.
    # (`Memo` names the counter-example that makes this worth asserting rather than assuming.)
    #
    # Asserted on the cache rather than through a build, because what is claimed is that the key
    # discriminates, and three of the four kinds cannot be built at all from this suite's fixtures
    # (no tags in the video, no detectable board at these dimensions). That `build_rectification`
    # keys on `c` itself is asserted by its `MEMOIZED` row above and by the testset before this one.
    #
    # `rectification_id` is one of the varied fields, so "two rows differing only in their id are two
    # entries" needs no testset of its own.
    @testset "every field of $(nameof(typeof(c))) is part of the build's key" for c in METHODS
        Fromage.empty_caches!()
        get!(() -> nothing, M.BUILT_RECTIFICATIONS, c)
        @test haskey(M.BUILT_RECTIFICATIONS, c)
        @testset "$name" for (name, variant) in variants(c)
            @test !haskey(M.BUILT_RECTIFICATIONS, variant)
        end
    end

    # The build half of "a failed read is never remembered", and it needs no machinery: `get!` stores
    # nothing when its closure throws. The AprilTag builder is the one that throws — it turns
    # `reference_space`'s report into an `error`, and this fixture has no tags in it — so a build
    # that failed on a bad row, or on a share hiccup (WHY-FRAMES-FAIL.md), is retried next time.
    @testset "a failed build is never remembered" begin
        c = VRect.Apriltag(VRect.Source(PLAIN, 1.0, missing, missing, 1.0, 320, 240), "no_tags", 4, "tag36h11", 12.0)
        Fromage.empty_caches!()
        @test_throws ErrorException Fromage.build_rectification(c)
        @test !haskey(M.BUILT_RECTIFICATIONS, c)
        @test_throws ErrorException Fromage.build_rectification(c)    # read again, failed again
        @test !haskey(M.BUILT_RECTIFICATIONS, c)
    end

    # The mirror of the issue-frame dump above: `rectification_diagnostics` is the CALLER's, not the
    # builder's (#209), so a cache hit still renders its image — from the cached object. A user
    # re-running to look at a rectification depends on that as much as on the report.
    @testset "the diagnostic image is written on every invocation, hit or miss" begin
        csv = joinpath(DIR, "memo_diagnostic.csv")
        open(csv, "w") do io
            println(io, "rectification_id,path,file,type,extrinsic,pixel_width")
            println(io, "d1,.,memo_plain.mp4,uniform,00:00:01,2")
        end
        outdir, rectify = rectifier(csv; rectification_diagnostics = true)
        jpg = joinpath(Fromage.Paths.rectifications_folder(outdir), "d1.jpg")

        Fromage.empty_caches!()
        rectify()
        @test isfile(jpg)

        # Removed, so the second pass has to write it again rather than leave the first one standing.
        rm(jpg)
        hits = M.hits(M.BUILT_RECTIFICATIONS)
        rectify()
        @test M.hits(M.BUILT_RECTIFICATIONS) == hits + 1       # served, not rebuilt
        @test isfile(jpg)                                      # ...and rendered anyway
    end

    # A failed READ is a fact about the share at that moment, not about the file, so it must not be
    # remembered — the next invocation has to be free to try again rather than re-report a hiccup for
    # the life of the session. Three of the five get that from `get!` storing nothing when its closure
    # throws; the other two recognize their own read-failure message and forget it (`Memo.remember`).
    # Both mechanisms are asserted the same way here: the failure is reported, and nothing is kept.
    @testset "a failed read is never remembered" begin
        corrupt = make_corrupt_video(joinpath(DIR, "memo_corrupt.mp4"))
        # valid MATLAB magic bytes, garbage after them: the header check passes and `matread` fails,
        # which is the .mat spelling of an unreadable file
        truncated = joinpath(DIR, "memo_truncated.mat")
        write(truncated, "MATLAB 5.0 MAT-file, then nothing that parses as one")

        entries = "stream=width,height"
        unreadable = (
            (
                name = "probe_fields", cache = M.VIDEO_PROBES, key = (corrupt, entries),
                f = () -> Fromage.Probing.probe_fields(corrupt, entries),
                says = "issue reading from video file: ",
            ),
            (
                name = "matlab_metadata", cache = M.MATLAB_METADATA, key = (truncated,),
                f = () -> VRect.matlab_metadata(truncated),
                says = VRect.MATLAB_OPEN_FAILURE,
            ),
            (
                name = "extrinsic_issue", cache = M.EXTRINSIC_DETECTIONS,
                key = (corrupt, 0.0, false, 0.0, 64, 64, (5, 8)),
                f = () -> VRect.extrinsic_issue(corrupt, 0.0, false, 0.0, 64, 64, (5, 8)),
                says = "issue with corner detection at the extrinsic time stamp: ",
            ),
            (
                name = "intrinsic_issue", cache = M.INTRINSIC_DETECTIONS,
                key = (corrupt, 0.0, 1.0, 0.5, false, 0.0, 64, 64, (5, 8)),
                f = () -> VRect.intrinsic_issue(corrupt, 0.0, 1.0, 0.5, false, 0.0, 64, 64, (5, 8)),
                says = "issue with corner detection in the intrinsic window: ",
            ),
            (
                name = "apriltag_extrinsic_issue", cache = M.APRILTAG_DETECTIONS,
                key = (corrupt, 0.0, 4, "tag36h11", 12),
                f = () -> PT.apriltag_extrinsic_issue(corrupt, 0.0, 4, "tag36h11", 12),
                says = PT.EXTRINSIC_READ_FAILURE,
            ),
        )

        # `says` is the message PREFIX, and the assertion below is deliberately not equality: each
        # of these carries ffmpeg's or MAT.jl's own words, and on Windows ffmpeg prints a POINTER in
        # them ("[mov,mp4,m4a,3gp,3g2,mj2 @ 000002966bbae940] moov atom not found"), which differs
        # between two reads of the same file. Two invocations must report the same FAILURE, which is
        # what the prefix pins; that the second call read at all is what `haskey` pins.
        @testset "$(u.name)" for u in unreadable
            issue = u.f()
            @test issue isa String                  # reported, not thrown
            @test startswith(issue, u.says)
            @test !haskey(u.cache, u.key)           # ...and nothing was kept
            @test startswith(u.f(), u.says)         # the next invocation reads again, and says the same
            @test !haskey(u.cache, u.key)
        end
    end

    # The tracking memo (#249), end to end through `main`: the user's loop is "watch the diagnostic
    # video, fix a row, run again", so every assertion is about what a second `main` tracked and what
    # it still WROTE. One dataset, re-written between invocations — csv text is never memoized, only
    # the videos it names, which are written once like every other fixture here.
    @testset "a second `main` re-tracks only the runs whose specification changed" begin
        rects_csv = joinpath(DIR, "memo_tracking.csv")
        write(rects_csv, "rectification_id,path,file,type,extrinsic,pixel_width\nu1,.,memo_plain.mp4,uniform,00:00:01,2\n")
        runs_csv = joinpath(DIR, "memo_tracking_runs.csv")
        outdir = mktempdir()
        results = joinpath(outdir, "results_dir")
        diagnostic = joinpath(results, "diagnostic.mp4")
        # `rows` are `run_id => stop`, a blank one tracking to the end of the video; the first row tracks
        # TARGET1 and the second TARGET2. Every invocation starts from an empty `results_dir`, so a
        # file found there afterwards was written by THAT invocation.
        function go(rows; run_ids = nothing)
            open(runs_csv, "w") do io
                println(io, "run_id,rectification_id,path,file,start_location,stop")
                for ((id, stop), file) in zip(rows, (TARGET1, TARGET2))
                    println(io, id, ",u1,.,", basename(file), ",\"(55, 50)\",", stop)
                end
            end
            rm(results; recursive = true, force = true)
            return cd(
                () -> Fromage.main(
                    DIR; rectifications_file = basename(rects_csv), runs_file = basename(runs_csv),
                    tracking_defaults = (target_width = 10,), run_ids
                ), outdir
            )
        end
        reused(n, of) = (:info, "Reused $n of $of tracks from earlier in this session; Fromage.empty_caches!() forces a re-track")
        X = ["t1" => "", "t2" => ""]
        Y = ["t1" => "", "t2" => "00:00:01"]

        # Cold: both tracked, and nothing said about reuse — `@test_logs` with no pattern asserts that
        # no log record was emitted at all.
        Fromage.empty_caches!()
        @test_logs go(X)
        @test (M.misses(M.TRACKED_RUNS), M.hits(M.TRACKED_RUNS)) == (2, 0)
        x_video = read(diagnostic)
        x_file = joinpath(mktempdir(), "diagnostic.mp4")      # the same bytes, where a decoder can read them
        write(x_file, x_video)
        font = PT.DIAGNOSTIC_SIZE ÷ 16                          # the rectified scene's, in `diagnose`
        x_csvs = read.(joinpath.(results, ["t1.csv", "t2.csv"]))
        @test probe_stream(diagnostic).nframes == 2 * 25        # two runs × 25 written frames each

        @testset "an unchanged dataset tracks nothing, and still writes everything" begin
            @test_logs reused(2, 2) go(X)
            @test (M.misses(M.TRACKED_RUNS), M.hits(M.TRACKED_RUNS)) == (2, 2)
            @test read.(joinpath.(results, ["t1.csv", "t2.csv"])) == x_csvs
            @test probe_stream(diagnostic).nframes == 2 * 25
        end

        @testset "editing one run's row re-tracks that run and no other" begin
            @test_logs reused(1, 2) go(Y)
            @test (M.misses(M.TRACKED_RUNS), M.hits(M.TRACKED_RUNS)) == (3, 3)
            @test probe_stream(diagnostic).nframes < 2 * 25        # t2 now tracked for half the video
        end

        # Track X, then Y, then revert to X. X's entry hits, and the video must show X's clip — which it
        # would not if the clip lived at a path Y had since overwritten, such as `results_dir/t2.mp4`.
        # That is why each entry has a folder of its own (DECISIONS).
        @testset "reverting a row serves the reverted row's clip, not the one tracked in between" begin
            y_video = read(diagnostic)
            @test_logs reused(2, 2) go(X)
            @test M.misses(M.TRACKED_RUNS) == 3
            @test read(diagnostic) == x_video
            @test read(diagnostic) != y_video
        end

        # `run_id` is part of the key, and is the clip's on-screen label (#22): a renamed run is
        # re-tracked, and the video differs from X's in that label and nothing else — same frame count.
        # Compared decoded, not as bytes: the renamed clip is a fresh encode, and encoding is not
        # byte-reproducible on every runner (#262), so unequal bytes would hold without the label. The
        # combined video is t1's 25 frames and then t2's: in t1's, the label region must differ and
        # the rest match; t2's clip was reused, so all of it must match. The tolerance is checked
        # from the other side below, where a re-encoded `t1` must match X inside the label too.
        @testset "renaming a run re-tracks it, and the video carries the new label" begin
            @test_logs reused(1, 2) go(["t1-renamed" => "", "t2" => ""])
            @test M.misses(M.TRACKED_RUNS) == 4
            @test isfile(joinpath(results, "t1-renamed.csv"))
            @test probe_stream(diagnostic).nframes == 2 * 25
            label, elsewhere = label_differences(diagnostic, x_file, ("t1", "t1-renamed"), font; frames = 1:25)
            @test all(>(LABEL_CHANGED), label)
            @test all(<(ENCODING_NOISE), elsewhere)
            @test all(<(ENCODING_NOISE), vcat(label_differences(diagnostic, x_file, ("t2",), font; frames = 26:50)...))
        end

        @testset "a narrowed invocation fills the entries a full one reuses" begin
            Fromage.empty_caches!()
            @test_logs go(X; run_ids = ["t1"])
            @test readdir(results) == ["diagnostic.mp4", "t1.csv"]
            @test_logs reused(1, 2) go(X)
            @test (M.misses(M.TRACKED_RUNS), M.hits(M.TRACKED_RUNS)) == (2, 1)
            # Both runs were tracked again after `empty_caches!`, so both clips were ENCODED again, and
            # re-encoding is not reproducible byte for byte: on the ubuntu runners the same dataset,
            # tracked twice from cold, decodes to different frames in one run's clip about half the
            # time, while its tracks match exactly (#262). So compare what tracking produced, not the
            # video's bytes. The byte comparison above, on reverting a row, stays: those clips are
            # served from the cache, so they are the same files.
            @test read.(joinpath.(results, ["t1.csv", "t2.csv"])) == x_csvs
            @test probe_stream(diagnostic).nframes == 2 * 25
            # What the renaming testset's tolerance must absorb: the same labels, encoded again, match
            # X's inside the label region as well as outside it.
            @test all(<(ENCODING_NOISE), vcat(label_differences(diagnostic, x_file, ("t1", "t2"), font)...))
        end
    end

    # The correctness half for tracking, the same claim the build's structural testset makes: every
    # field of the run — its tuning, frame format and segments field by field included — and every
    # field of the rectification method is part of the key. Asserted on the cache with a sentinel
    # entry rather than by tracking every variant, most of which could not be tracked at all.
    #
    # `Run` cannot be the key itself: it is an immutable struct holding a `Vector`, so two identically
    # specified runs compare `===`-unequal and hash differently. The first assertion is that the key
    # nevertheless finds an identically specified run built separately.
    @testset "every field of the run and of $(nameof(typeof(c))) is part of the track's key" for c in METHODS
        Fromage.empty_caches!()
        get!(() -> ((), joinpath(mktempdir(), "sentinel.mp4")), M.TRACKED_RUNS, Fromage.tracking_key(RUN, c))
        @test haskey(M.TRACKED_RUNS, Fromage.tracking_key(deepcopy(RUN), deepcopy(c)))
        @testset "$name" for (name, variant) in variants(RUN)
            @test !haskey(M.TRACKED_RUNS, Fromage.tracking_key(variant, c))
        end
        @testset "$name" for (name, variant) in variants(c)
            @test !haskey(M.TRACKED_RUNS, Fromage.tracking_key(RUN, variant))
        end
    end

    # A failed track stores nothing (`get!` never does when its closure throws) and leaves no folder
    # behind in the session's clip folder; a run that succeeded in the same invocation stays cached, so
    # the rerun after a crash or a Ctrl-C tracks only what did not finish.
    @testset "a failed track is never remembered, and a finished one is" begin
        c = METHODS[1]
        broken = replace_field(RUN, 5, [PT.Segment(UNTRACKABLE, 0.0, 1.0, (55, 50))])
        Fromage.empty_caches!()
        @test_throws TaskFailedException Fromage.track_runs([RUN, broken], [c, c])
        @test haskey(M.TRACKED_RUNS, Fromage.tracking_key(RUN, c))
        @test !haskey(M.TRACKED_RUNS, Fromage.tracking_key(broken, c))
        @test length(readdir(M.CLIP_FOLDER())) == 1                 # the finished run's, and only that
        hits = M.hits(M.TRACKED_RUNS)
        Fromage.track_run(RUN, c)
        @test M.hits(M.TRACKED_RUNS) == hits + 1
    end

    # A clip lives exactly as long as its entry: `LRU`'s finalizer runs on eviction and on `empty!`, so
    # neither `empty_caches!` nor a full cache leaves a file behind.
    @testset "a track's clip is deleted with its entry" begin
        Fromage.empty_caches!()
        clip = Fromage.track_run(RUN, METHODS[1]).clip
        @test isfile(clip)
        @test basename(clip) == "memo_run.mp4"                      # the label (#22)
        @test dirname(dirname(clip)) == M.CLIP_FOLDER()
        Fromage.empty_caches!()
        @test !ispath(dirname(clip))

        clip = Fromage.track_run(RUN, METHODS[1]).clip
        resize!(M.TRACKED_RUNS; maxsize = 0)                        # evicts the one entry
        resize!(M.TRACKED_RUNS; maxsize = M.CACHE_SIZE)
        @test isempty(M.TRACKED_RUNS)
        @test !ispath(dirname(clip))
        @test isempty(readdir(M.CLIP_FOLDER()))
    end

    # The bound is a guard, not a working set, and must never cost an invocation its own clips: with
    # more runs than the cache holds, the first ones tracked would be evicted — their clips deleted —
    # before `concatenate` reached them. `main` raises the bound to its run count first.
    @testset "an invocation of more runs than the cache holds keeps every clip it stitches" begin
        rects_csv = joinpath(DIR, "memo_room.csv")
        write(rects_csv, "rectification_id,path,file,type,extrinsic,pixel_width\nu1,.,memo_plain.mp4,uniform,00:00:01,2\n")
        runs_csv = joinpath(DIR, "memo_room_runs.csv")
        write(
            runs_csv, "run_id,rectification_id,path,file,start_location\n" *
                "a,u1,.,$(basename(TARGET1)),\"(55, 50)\"\nb,u1,.,$(basename(TARGET2)),\"(55, 50)\"\n"
        )
        outdir = mktempdir()
        Fromage.empty_caches!()
        resize!(M.TRACKED_RUNS; maxsize = 1)
        try
            cd(
                () -> Fromage.main(
                    DIR; rectifications_file = basename(rects_csv), runs_file = basename(runs_csv),
                    tracking_defaults = (target_width = 10,)
                ), outdir
            )
            @test length(M.TRACKED_RUNS) == 2                   # nothing evicted
            @test probe_stream(joinpath(outdir, "results_dir", "diagnostic.mp4")).nframes == 2 * 25
        finally
            resize!(M.TRACKED_RUNS; maxsize = M.CACHE_SIZE)
        end
    end

    @testset "empty_caches! clears every cache in the package" begin
        # Prime every cache, whatever the tests above left behind, through the memoized functions
        # themselves — a cache holds what its own computation returns, so there is no sentinel value
        # that fits them all.
        foreach(m -> m.f(m.base...), MEMOIZED)
        @test all(!isempty, M.CACHES)
        Fromage.empty_caches!()
        @test all(isempty, M.CACHES)

        # The list `empty_caches!` walks must not fall behind the caches that exist: a sixth cache
        # added anywhere in the package and not registered would be cleared by nothing, which is the
        # kind of omission that only surfaces as a stale read months later.
        function every_cache(m::Module, seen = Set{Module}(), found = Any[])
            m in seen && return found
            push!(seen, m)
            for n in names(m; all = true)
                isdefined(m, n) || continue
                v = getfield(m, n)
                v isa LRU && push!(found, v)
                v isa Module && parentmodule(v) === m && v !== m && every_cache(v, seen, found)
            end
            return found
        end
        found = every_cache(Fromage)
        @test !isempty(found)
        @test all(c -> any(r -> r === c, M.CACHES), found)
        @test length(found) == length(M.CACHES)
    end
end

end
