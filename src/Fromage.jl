module Fromage

# The four packages of the tracking ecosystem, consolidated as submodules (one repo, one version,
# one test suite; see the README). Include order matters: Rectifications is used by
# VerifyRectifications, PawsomeTracker by VerifyRuns, and the three shared modules by both
# gateways -- Parsing (CSV-cell machinery), Probing (ffprobe plumbing) and Gateway (the csv ->
# verified DataFrame pipeline the two gateways run in common).
include("Rectifications/Rectifications.jl")
include("PawsomeTracker/PawsomeTracker.jl")
include("parsing.jl")
include("probing.jl")
include("gateway.jl")
include("VerifyRectifications/VerifyRectifications.jl")
include("VerifyRuns/VerifyRuns.jl")

using .Rectifications: Rectification
using .PawsomeTracker: track
using .VerifyRectifications: load_rectifications, RectificationMethod
using .VerifyRuns: load_runs, Run

using DataFrames: DataFrame, Not, leftjoin!, select!, transform!
using FFMPEG: ffmpeg_exe
using OhMyThreads: tforeach, tmap
using ProgressMeter: @showprogress

export main

include("main.jl")

end # module Fromage
