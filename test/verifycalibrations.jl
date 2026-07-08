module VerifyCalibrationsTests

using Test
using Fromage: Fromage

include("VerifyCalibrations/helpers.jl")

# Shared artifacts and CSV scratch space, built once (ffmpeg is the slow part).
const DATADIR = mktempdir()
const ART = setup_artifacts(DATADIR)

@testset "VerifyCalibrations" begin
    include("VerifyCalibrations/test_input.jl")
    include("VerifyCalibrations/test_parsing.jl")
    include("VerifyCalibrations/test_filesystem.jl")
    include("VerifyCalibrations/test_structural.jl")
    include("VerifyCalibrations/test_reading.jl")
    include("VerifyCalibrations/test_video_metadata.jl")
    include("VerifyCalibrations/test_extrinsic_index.jl")
    include("VerifyCalibrations/test_values.jl")
    include("VerifyCalibrations/test_extrinsics.jl")
    include("VerifyCalibrations/test_intrinsics.jl")
    include("VerifyCalibrations/test_strict.jl")
    include("VerifyCalibrations/test_happy.jl")
    include("VerifyCalibrations/test_integration.jl")
end

end
