module RectificationsTests

using Test
using Fromage: Rectifications
using StaticArrays
using LinearAlgebra
using CoordinateTransformations
using Rotations
using Logging

# Most of the submodule's functions are internal (not exported); reach them through the module.
const R = Rectifications

@testset "Rectifications" begin
    # Tier 1 — pure, deterministic functions (no ffmpeg / OpenCV / I/O).
    include("Rectifications/test_lens_distortion.jl")
    include("Rectifications/test_geometry.jl")
    include("Rectifications/test_ffmpeg_cmd.jl")
    include("Rectifications/test_module_state.jl")
    include("Rectifications/test_from_scale.jl")

    # Tier 2 — OpenCV-backed corner detection & camera-model fit (synthetic data, no video).
    include("Rectifications/test_calibration.jl")

    # Tier 3 — full pipeline over a synthesized checkerboard video (bundled ffmpeg + OpenCV).
    include("Rectifications/test_rectification.jl")

    # Tier 4 — concurrency regression: the global read semaphore bounds simultaneous reads.
    include("Rectifications/test_concurrency.jl")
end

end
