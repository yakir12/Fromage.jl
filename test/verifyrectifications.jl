module VerifyRectificationsTests

using Test
using Fromage: Fromage
using ..Fixtures, ..Harness

# Shared artifacts and CSV scratch space, built once for the whole suite. DATADIR comes
# first: helpers.jl generates into it and closes over it.
const DATADIR = mktempdir()

include("VerifyRectifications/helpers.jl")

@testset "VerifyRectifications" begin
    include("VerifyRectifications/test_input.jl")
    include("VerifyRectifications/test_parsing.jl")
    include("VerifyRectifications/test_defaults.jl")
    include("VerifyRectifications/test_filesystem.jl")
    include("VerifyRectifications/test_structural.jl")
    include("VerifyRectifications/test_reading.jl")
    include("VerifyRectifications/test_video_metadata.jl")
    include("VerifyRectifications/test_extrinsic_index.jl")
    include("VerifyRectifications/test_values.jl")
    include("VerifyRectifications/test_extrinsics.jl")
    include("VerifyRectifications/test_intrinsics.jl")
    include("VerifyRectifications/test_strict.jl")
    include("VerifyRectifications/test_happy.jl")
    include("VerifyRectifications/test_integration.jl")
end

end
