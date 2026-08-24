# Package-wide Aqua / ExplicitImports checks.
module QualityTests

using Test
using Aqua
using ExplicitImports
using Fromage

@testset "quality" begin
    @testset "Aqua" begin
        # ambiguities are skipped: the heavy image/OpenCV dependency stack reports ambiguities in
        # methods this package doesn't own.
        Aqua.test_all(Fromage; ambiguities = false)
    end

    @testset "ExplicitImports" begin
        # These checks recurse into every submodule, so passing `Fromage` covers Rectifications,
        # PawsomeTracker, VerifyRectifications and VerifyRuns too — the whole package imports every
        # name explicitly, via its owning module. ImageIO is exempted from the stale check: it is
        # imported purely for its side effect (registering FileIO's image backend), never by name.
        @test check_no_implicit_imports(Fromage) === nothing
        @test check_no_stale_explicit_imports(Fromage; ignore = (:ImageIO,)) === nothing
        @test check_all_explicit_imports_via_owners(Fromage) === nothing
        @test check_all_qualified_accesses_via_owners(Fromage) === nothing
        @test check_no_self_qualified_accesses(Fromage) === nothing
    end

    # The structural invariant behind #140 and #141. Both issues came from a tuning parameter
    # having TWO definition sites — the verification stage and the consuming function's kwarg
    # default — with an open `kwargs...` channel between them. Prose and review did not keep that
    # from happening; this does, by failing the moment a parameter appears on one side only.
    #
    # Read as two directions:
    #   forward (#141) — nothing reaches a consumer that the csv did not describe and the gateway
    #                    did not verify;
    #   reverse (#140) — nothing is settable that fails to reach a consumer.
    @testset "every tuning parameter has exactly one definition site (#140, #141)" begin
        PT = Fromage.PawsomeTracker
        VRuns = Fromage.VerifyRuns
        VRect = Fromage.VerifyRectifications

        @testset "track takes no keyword arguments" begin
            # The whole point of Segment/Tuning. A keyword here would be a second definition of
            # something the gateway already decided, and — because a later splatted keyword
            # silently beats an earlier one — a way to override a verified value with an
            # unverified one.
            for m in methods(PT.track)
                @test isempty(Base.kwarg_decl(m))
            end
        end

        @testset "every tracking parameter is a runs.csv column" begin
            # `video_fps` is the one exception, and it is not a loophole: it is probed from the
            # video by the gateway, never written by a user, and bounds-checks `fps`.
            probed = Set([:video_fps])
            @test Set(fieldnames(PT.Tuning)) ⊆ Set(VRuns.COLUMNS) ∪ probed
            @test Set(fieldnames(PT.Segment)) ⊆ Set(VRuns.COLUMNS)

            # reverse: everything `tracking_defaults` may set actually lands on a Tuning field
            @test Set(keys(VRuns.DEFAULTS)) ⊆ Set(fieldnames(PT.Tuning))
        end

        @testset "every rectification parameter is a calibs.csv column" begin
            builders = [Fromage.Rectifications.from_video, Fromage.Rectifications.from_extrinsic,
                        Fromage.Rectifications.from_matlab, Fromage.Rectifications.from_scale,
                        PT.ApriltagRectification]
            # width/height are probed from the video; `ntags` is the `apriltags` column under the
            # name the builder gives it; `rectification_diagnostics` is a caller instruction, not
            # data — it is the one thing here `main` legitimately defaults.
            allowed = Set(VRect.COLUMNS) ∪ Set([:width, :height, :ntags, :rectification_diagnostics])
            for f in builders, m in methods(f)
                @test Set(Base.kwarg_decl(m)) ⊆ allowed
            end

            # reverse: everything `rectification_defaults` may set reaches a builder. `apriltags`
            # is spelled `ntags` there, which is exactly the kind of rename this catches.
            # Over ALL methods, not `first(methods(f))`: method order is not specified, and
            # `ApriltagRectification` is a struct, so one of its methods is the positional
            # constructor with no keywords at all.
            consumed = reduce(union, (Set(Base.kwarg_decl(m)) for f in builders for m in methods(f)))
            @test Set(keys(VRect.DEFAULTS)) ⊆ consumed ∪ Set([:apriltags])
        end

        @testset "the rectification dispatchers swallow nothing" begin
            # `Rectification(c; kwargs...)` used to splat whatever arrived onward — and the
            # apriltag method forwarded none of it, so even a correct keyword was a silent no-op.
            @test !isempty(methods(Fromage.Rectifications.Rectification))
            for m in methods(Fromage.Rectifications.Rectification)
                @test Base.kwarg_decl(m) == [:rectification_diagnostics]
            end
        end
    end
end

end
