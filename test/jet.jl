# JET static analysis: abstract interpretation of the whole package, reporting only what
# originates in Fromage's own modules (dependencies produce plenty of noise of their own).
# Included from runtests.jl only on the pinned Julia minor: JET couples to compiler internals,
# so a new Julia release must not be able to break the suite through JET.
using JET: JET, @test_opt
using Fromage: Fromage, Rectifications, PawsomeTracker
using StaticArrays: SVector, SMatrix

const R = Rectifications
const PT = PawsomeTracker

@testset "JET" begin
    JET.test_package(Fromage; target_modules = (Fromage,))

    # `test_package` above runs JET's ERROR analysis — undefined bindings, method errors. It does
    # not run the OPTIMIZATION analysis, so runtime dispatch is invisible to it, and a change that
    # made a hot path dynamic would land with CI green.
    #
    # That is not hypothetical. `lens_distortion_factor` is `evalpoly(r^2, (1.0, k...))`, which is
    # free only while `k` is an NTuple: splatting a Vector builds a non-concrete
    # `Tuple{Float64, Vararg{Float64}}`, costing a heap allocation and a dynamic call every time —
    # measured at 120x per call and 15x on a full frame warp, with nothing in the suite going red.
    # `k` is pinned to `NTuple{3,Float64}` at both producers (`fit_model`, `from_matlab`) precisely
    # so that stays true; this is what keeps it true.
    #
    # Deliberately a CURATED LIST, not the package. `report_opt` over everything would report
    # dispatch inside VideoIO, OpenCV, DataFrames and ffmpeg — none of it actionable, and enough of
    # it to bury the signal. What is listed here is pure computation on concrete types, where a
    # runtime dispatch is always a bug rather than a fact of life about a dependency.
    #
    # It lives under the same Julia pin as the analysis above, and more urgently: `report_opt` reads
    # the compiler's inlining decisions, so an unpinned version of this could go red on a new Julia
    # minor with no change to this package at all.
    @testset "no runtime dispatch on the numeric hot paths" begin
        k = (0.1, -0.02, 0.005)                      # the shape both producers now yield
        v = SVector(0.31, -0.12)
        H = SMatrix{3, 3, Float64}(1.5, -0.03, 5e-6, 0.05, 1.5, 3e-6, 960.0, 540.0, 1.0)
        pts = SVector{2, Float64}[SVector(0.0, 0.0), SVector(1.0, 0.0), SVector(1.0, 1.0), SVector(0.0, 1.0)]
        dst = SVector{2, Float64}[SVector(2.0, 3.0), SVector(3.0, 3.0), SVector(3.0, 4.0), SVector(2.0, 4.0)]

        # the lens model: called per tracked coordinate, and per pixel of every warped frame
        @test_opt R.lens_distortion_factor(0.37, k)
        @test_opt R.lens_distortion(v, k)
        @test_opt R._first_critical(k)
        @test_opt R.inv_lens_distortion(v, k, 2.0)

        # the AprilTag geometry: called per corner inside the metric fit's iteration
        @test_opt PT.apply_h(H, v)
        @test_opt PT.rigid_align(pts, dst)
        @test_opt PT.homography_dlt(pts, dst)
    end
end
