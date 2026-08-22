module Fromage

# The four packages of the tracking ecosystem, consolidated as submodules (one repo, one version,
# one test suite; see the README). Include order matters: Paths is first because both `main` and
# VerifyRectifications derive their output folders from it, ShareIO next because all three
# share-reading paths depend on it, Rectifications is used by VerifyRectifications and (for the
# `RowCol` alias) by PawsomeTracker, PawsomeTracker by VerifyRuns, and the three shared modules by
# both gateways -- Parsing (CSV-cell machinery), Probing (ffprobe plumbing) and Gateway (the csv ->
# verified DataFrame pipeline the two gateways run in common).
include("paths.jl")
include("shareio.jl")
include("Rectifications/Rectifications.jl")
include("PawsomeTracker/PawsomeTracker.jl")
include("parsing.jl")
include("probing.jl")
include("gateway.jl")
include("VerifyRectifications/VerifyRectifications.jl")
include("VerifyRuns/VerifyRuns.jl")

using .Paths: results_dir, DEFAULT_ISSUES_DIR
using .Gateway: verify_cross_references!
using .Rectifications: Rectification
using .PawsomeTracker: track
using .VerifyRectifications: load_rectifications, RectificationMethod
using .VerifyRuns: load_runs, Run

using DataFrames: AbstractDataFrame, DataFrame, Not, leftjoin!, select!, transform!
using FFMPEG: ffmpeg_exe
using OhMyThreads: tforeach, tmap
using ProgressMeter: @showprogress

export main

include("main.jl")

end # module Fromage
