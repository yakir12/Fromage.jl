# Code-quality checks for the consolidated package, replacing the per-package Aqua /
# ExplicitImports tests the former packages carried.
module QualityTests

using Test
using Aqua
using ExplicitImports
using Fromage

@testset "quality" begin
    @testset "Aqua" begin
        # ambiguities are skipped: the heavy image/OpenCV dependency stack reports ambiguities in
        # methods this package doesn't own (the former packages skipped them too).
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
end

end
