module VerifyRunsTests

using Test
using Fromage: Fromage

include("VerifyRuns/helpers.jl")

# Shared artifacts and CSV scratch space, built once (ffmpeg is the slow part).
const DATADIR = mktempdir()
const ART = setup_artifacts(DATADIR)

@testset "VerifyRuns" begin
    include("VerifyRuns/test_input.jl")
    include("VerifyRuns/test_parsing.jl")
    include("VerifyRuns/test_defaults.jl")
    include("VerifyRuns/test_filesystem.jl")
    include("VerifyRuns/test_video_metadata.jl")
    include("VerifyRuns/test_values.jl")
    include("VerifyRuns/test_segments.jl")
    include("VerifyRuns/test_strict.jl")
    include("VerifyRuns/test_happy.jl")
    include("VerifyRuns/test_gatekeeper.jl")
    include("VerifyRuns/test_tracking.jl")
end

end
