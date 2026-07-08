module Fromage

# The four packages of the tracking ecosystem, consolidated as submodules (one repo, one version,
# one test suite; see the README). Order matters: Rectifications is used by VerifyRectifications,
# and PawsomeTracker by VerifyRuns.
include("Rectifications/Rectifications.jl")
include("PawsomeTracker/PawsomeTracker.jl")
include("VerifyRectifications/VerifyRectifications.jl")
include("VerifyRuns/VerifyRuns.jl")

using .Rectifications: Rectification
using .PawsomeTracker: track
using .VerifyRectifications: load_rectifications
using .VerifyRuns: load_runs

using DataFrames: DataFrame, Not, leftjoin!, select!, transform!
using FFMPEG: ffmpeg_exe
using OhMyThreads: tmap
using ProgressMeter: @showprogress

export main

include("main.jl")

end # module Fromage
