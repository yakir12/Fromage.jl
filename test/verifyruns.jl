module VerifyRunsTests

using Test
using Fromage: Fromage
using ..Fixtures, ..Harness

# Shared artifacts and CSV scratch space, built once for the whole suite. DATADIR comes
# first: helpers.jl generates into it and closes over it.
const DATADIR = mktempdir()

include("VerifyRuns/helpers.jl")

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
