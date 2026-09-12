# The memo behind the iterate-on-your-csv workflow (#233): verification remembers every read and
# every detection for the life of the Julia process, so a second `main`/`verify` over an unchanged
# dataset spawns no ffprobe, reads no `.mat` and detects nothing.
#
# Two things are asserted here, and the second is the one that matters. That the caches HIT is a
# performance claim, and it is asserted on the hit/miss counters rather than on wall-clock time,
# which on this machine is noise (DECISIONS). That every parameter a memoized computation reads is
# part of its key is a CORRECTNESS claim: an under-specified key is the one way this change can
# return a wrong answer rather than merely a slow one, so each parameter is varied on its own and
# the recomputation asserted, rather than reasoned about from the source.
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

# What every cache in the package has computed so far, by identity. The counters are process-global
# and other suites share them, so every assertion below is on a DELTA taken around one call.
snapshot(caches = M.CACHES) = map(M.misses, caches), map(M.hits, caches)

# A failing extrinsic detection appends the path it dumped the frame to, and that path names the
# INVOCATION's own folder — so two verifications of one failing dataset must agree on the verdict
# and differ on the path. These two split a report into those halves.
const SAVED_TAIL = " — saved the extrinsic frame to "
const SAVED_SUFFIX = " for inspection"
verdicts(df) = [[first(split(m, SAVED_TAIL)) for m in msgs] for msgs in skipmissing(df.issues)]
saved_frames(df) = [
    chopsuffix(String(last(split(m, SAVED_TAIL))), SAVED_SUFFIX)
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

# The board video's own frame size — the checkerboard png padded to even dimensions. Read off the
# file rather than hard-coded, since the detectors are keyed on it and a wrong value would silently
# turn every detection into a reshape failure instead of a detection.
const BOARD_W, BOARD_H = let f = Fromage.Probing.probe_fields(BOARD, "stream=width,height")
    parse(Int, f["width"]), parse(Int, f["height"])
end

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
)

@testset "Memo (verification remembers what it read)" begin

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

        # One issues root for both passes, so the per-invocation folders land side by side and can
        # be told apart.
        idir = mktempdir()
        check_rects() = VRect.check_rectifications(DIR, csv; issues_dir = idir)
        check_runs() = VRuns.check_runs(DIR, runs_csv)

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
        @test all(==(idir) ∘ dirname ∘ dirname, [saved_frames(first_rects); saved_frames(second_rects)])

        # After `empty_caches!` the same dataset is read from scratch again, with the same verdict.
        Fromage.empty_caches!()
        third_rects, third_runs = check_rects(), check_runs()
        @test all(map(M.misses, M.CACHES) .> 0)                # counters reset by empty!, so this is the fresh count
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

    @testset "empty_caches! clears every cache in the package" begin
        # Prime all five, whatever the tests above left behind, through the memoized functions
        # themselves — a cache holds what its own computation returns, so there is no sentinel value
        # that fits all five.
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
