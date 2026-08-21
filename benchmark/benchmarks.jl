# Benchmarks for Fromage. The runner is a choice; `SUITE` is the contract.
#
#     benchpkg Fromage --rev=main,my-branch          # AirspeedVelocity, from the repo root
#     using PkgBenchmark; judge("Fromage", "my-branch", "main")
#
# Two tiers, because one sampling strategy cannot serve both:
#
#   "micro" — pure, in-memory, deterministic. BenchmarkTools samples these properly and the
#             numbers mean what they say, so this is the tier that can settle a design question.
#   "macro" — whole pipelines: decoding video, spawning ffprobe, encoding an .mp4. A sampled
#             statistic here would measure the filesystem and the scheduler, not the code, so
#             each runs once and reports wall clock and allocations. Read them as a regression
#             tripwire, not as a measurement — and not at all on a busy machine.
#
# What this cannot tell you: nothing here touches a network filesystem. The threading shape in
# `track` and `main` exists to survive EAGAIN on a CIFS share under concurrent ffmpeg reads, and
# that is a contention failure no local benchmark reproduces. Measuring it needs a hand-run
# against the real data (#68, candidate 06).

using BenchmarkTools
using ColorTypes: Gray
using ComputationalResources: CPU1, CPUThreads
using FixedPointNumbers: N0f8
using Fromage: Fromage, main
using Fromage.PawsomeTracker: track
using ImageFiltering: Algorithm, Kernel, NoPad, imfilter!
using OffsetArrays: OffsetMatrix
using PaddedViews: PaddedView
using StaticArrays: SVector

const R = Fromage.Rectifications
const PT = Fromage.PawsomeTracker

# The test suite's synthetic media, so a benchmark and a test measure the same fixture.
include(joinpath(@__DIR__, "..", "test", "fixtures.jl"))
using .Fixtures

const DATADIR = mktempdir()
const SUITE = BenchmarkGroup()

# ---------------------------------------------------------------------------
# micro — pure and deterministic
# ---------------------------------------------------------------------------

# A realistic barrel distortion: two radial coefficients with k₁ < 0, so the map folds and
# `inv_lens_distortion` takes its bracketed branch rather than the doubling one. The fold sits at
# r ≈ 1.09, well outside the sampled radii, so no point is clamped.
const K = (-0.28, 0.09)
const RSTAR = R._first_critical(K)
# one row of a 640-wide frame in normalised image coordinates — the granularity the warp works at
const PIXELS = [SVector(0.0, x) for x in range(-0.6, 0.6; length = 640)]

lens = SUITE["micro"]["lens distortion"] = BenchmarkGroup()
lens["_first_critical"] = @benchmarkable R._first_critical($K)
lens["forward, 640 px"] = @benchmarkable [R.lens_distortion(v, $K) for v in $PIXELS]
lens["inverse, 640 px"] = @benchmarkable [R.inv_lens_distortion(v, $K, $RSTAR) for v in $PIXELS]

# An only_scale rectification: no video is read unless `rectification_diagnostics` asks for one, so
# this is a pure pair of coordinate maps.
const RECT = R.from_scale(; file = "unread.mp4", extrinsic = 0, calibration_id = "bench",
    scale = 0.05, aspect = 1.0, center = missing, north = missing, width = 640, height = 480)
const IMAGE_PTS = vec([SVector(float(r), float(c)) for r in 1:16:480, c in 1:16:640])
const REAL_PTS = map(RECT.image2real, IMAGE_PTS)

geom = SUITE["micro"]["geometry"] = BenchmarkGroup()
geom["image2real, 1200 pts"] = @benchmarkable map($(RECT.image2real), $IMAGE_PTS)
geom["real2image, 1200 pts"] = @benchmarkable map($(RECT.real2image), $REAL_PTS)

# The AprilTag ground geometry, on the four-tag layout the tests use: all closed-form, no detector.
const HOMOG = SVector{2, Float64}[SVector(1400, 880), SVector(1500, 890), SVector(1490, 970), SVector(1395, 965)]
const HOMOG_DST = SVector{2, Float64}[SVector(0, 0), SVector(96, 0), SVector(96, 96), SVector(0, 96)]
const TAG = [SVector(c[1] + 400, c[2] - 400) for c in PT.CANON]

tags = SUITE["micro"]["apriltag geometry"] = BenchmarkGroup()
tags["homography_dlt"] = @benchmarkable PT.homography_dlt($HOMOG, $HOMOG_DST)
tags["place_square"] = @benchmarkable PT.place_square($TAG)

# Candidate 06 asks whether `imfilter!(CPUThreads(...))` earns its keep on a search window a few
# tens of pixels wide. Measured against the serial algorithm on the same window and the same
# kernel, with no tracker internals in the way, so the comparison outlives whatever `detect`
# becomes. The shapes come from the tracker's own defaults: a 10 px target, a 21×21 window.
const SIGMA = PT.get_sigma(10)
const DOG = -1 * Kernel.DoG((SIGMA, SIGMA))
const RADII = (10, 10)
const FRAME_SZ = (480, 640)
const PAD = UnitRange.(1 .- (RADII .+ size(DOG)), FRAME_SZ .+ (RADII .+ size(DOG)))
const FILT_IN = PaddedView(zero(Gray{Float32}),
    Gray{Float32}.(reshape(range(0, 1; length = prod(FRAME_SZ)), FRAME_SZ)), PAD)
const FILT_OUT = OffsetMatrix(Matrix{Float64}(undef, length.(PAD)), PAD)
const WINDOW = UnitRange.((240, 320) .- RADII, (240, 320) .+ RADII)

filt = SUITE["micro"]["detection filter"] = BenchmarkGroup()
filt["DoG over a 21x21 window, CPUThreads"] =
    @benchmarkable imfilter!(CPUThreads(Algorithm.FIR()), $FILT_OUT, $FILT_IN, $DOG, NoPad(), $WINDOW)
filt["DoG over a 21x21 window, CPU1"] =
    @benchmarkable imfilter!(CPU1(Algorithm.FIR()), $FILT_OUT, $FILT_IN, $DOG, NoPad(), $WINDOW)

# ---------------------------------------------------------------------------
# macro — whole pipelines, one shot each
# ---------------------------------------------------------------------------

# The shared disc fixture: 100×100, 2 s at 25 fps, lossless, analytic trajectory.
const TARGET = joinpath(DATADIR, only(first(make_target_video(DATADIR, "bench_target"))))

# A complete data folder for `main`: one checkerboard calibration and one run over the disc. The
# CSVs deliberately omit n_corners and target_width, so both gateways' defaults are exercised.
const MAIN_DIR = let dir = mktempdir()
    png = joinpath(@__DIR__, "..", "test", "VerifyRectifications", "fixtures", "checkerboard.png")
    make_checkerboard_video(joinpath(dir, "board.mp4"), png)
    target, _ = make_target_video(dir, "run")
    write(joinpath(dir, "calibs.csv"),
        "calibration_id,file,type,extrinsic,start,stop,checker_size\nc1,board.mp4,video,1,0,4,4\n")
    write(joinpath(dir, "runs.csv"),
        "calibration_id,file,start_location\nc1,$(only(target)),\"(55, 50)\"\n")
    dir
end

# `main` writes results_dir relative to the working directory, so each run gets a fresh one.
run_main() = cd(() -> main(MAIN_DIR; rectification_defaults = (n_corners = (5, 8),),
                                     tracking_defaults = (target_width = 10,)), mktempdir())

# The gateways, without any video: every path points at a file that does not exist, so each row is
# parsed, verified and reported but nothing is probed. That isolates the DataFrames work — column
# typing, `subset`, `groupby`, the issue accumulation — from ffprobe, which otherwise dominates.
const GATEWAY_DIR = let dir = mktempdir(), n = 200
    write(joinpath(dir, "runs.csv"),
        "run_id,calibration_id,file,start_location\n" *
        join(["r$i,c$(i % 5),nope_$i.mp4,\"(55, 50)\"" for i in 1:n], '\n') * "\n")
    write(joinpath(dir, "calibs.csv"),
        "calibration_id,type,file,extrinsic,scale\n" *
        join(["c$i,only_scale,nope_$i.mp4,1,2" for i in 0:4], '\n') * "\n")
    dir
end

# Every row ends up flagged, so the run also pays for building and printing the issue report. That
# is a constant across revisions; allocations are the cleaner signal for whether machinery was
# actually removed.
gates = SUITE["micro"]["gateways"] = BenchmarkGroup()
gates["load_runs, 200 rows"] =
    @benchmarkable Fromage.VerifyRuns.load_runs(joinpath($GATEWAY_DIR, "runs.csv"); strict = false)
gates["load_rectifications, 5 rows"] =
    @benchmarkable Fromage.VerifyRectifications.load_rectifications(joinpath($GATEWAY_DIR, "calibs.csv"); strict = false)

pipe = SUITE["macro"] = BenchmarkGroup()
pipe["track, 50 frames"] =
    @benchmarkable(track($TARGET; start_location = (55, 50), target_width = 10),
                   samples = 1, evals = 1)
pipe["track + diagnostic video"] =
    @benchmarkable(track($TARGET; start_location = (55, 50), target_width = 10,
                         diagnostic_file = joinpath(mktempdir(), "d.mp4")),
                   samples = 1, evals = 1)
pipe["main, one calibration + one run"] = @benchmarkable(run_main(), samples = 1, evals = 1)
