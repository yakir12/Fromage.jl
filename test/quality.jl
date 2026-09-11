# Package-wide Aqua / ExplicitImports checks.
module QualityTests

using Test
using Aqua
using ExplicitImports
using Fromage

# Four small parser helpers for the #159 testset below, which has to ask what the OTHER suite
# files *call*. Running them cannot answer that, and reading them as text answers it wrongly: a
# comment about a check is not a call to it, and the first version of this testset failed on its
# own explanation. The parser has thrown the comments away before any of this looks at anything.

"""The bare name a callee ends in: `f` for both `f(…)` and `Mod.f(…)`, `nothing` for anything that
is not a name. Three methods rather than an `isa` chain, on a closed set: `Expr.args` holds `Any`,
and a literal in call position genuinely has no name."""
callee_name(f::Symbol) = f
callee_name(f::Expr) = f.head === :. && f.args[2] isa QuoteNode ? f.args[2].value : nothing
callee_name(::Any) = nothing

"""Every call to a function named `name`, at any depth in `ex` — including inside macro arguments
and quoted expressions, which the parser leaves as ordinary `Expr` trees."""
function calls_to(ex, name::Symbol, found = Expr[])
    ex isa Expr || return found
    ex.head === :call && callee_name(ex.args[1]) === name && push!(found, ex)
    foreach(arg -> calls_to(arg, name, found), ex.args)
    return found
end

"""Does `call` pass `name = value` as one of its OWN keyword arguments? Those sit directly in
`args` when written without a semicolon and under a `:parameters` node when written after one —
two places, and deliberately no deeper: a `:kw` further down belongs to a nested expression, not
to this call, and recursing would let `f(x; opts = (; persistent_tasks = false))` answer yes."""
function passes_keyword(call::Expr, name::Symbol, value)
    is_kw(a) = a isa Expr && a.head === :kw && a.args[1] === name && a.args[2] === value
    return any(call.args) do arg
        is_kw(arg) || (arg isa Expr && arg.head === :parameters && any(is_kw, arg.args))
    end
end

"""Every file the default suite reaches, following `include` from `runtests.jl`. An `include` whose
path is not a literal cannot be followed, and quietly not following one would be a hole in the
invariant below rather than a gap in coverage — so it throws. `test/tolerance_residuals.jl` already
writes `include(joinpath(@__DIR__, …))`, which is exactly the form that would otherwise slip past."""
function included_files(path::AbstractString, seen = String[])
    path in seen && return seen
    push!(seen, path)
    for call in calls_to(Meta.parseall(read(path, String); filename = path), :include)
        length(call.args) == 2 && call.args[2] isa String ||
            error("$path: `$call` has a path this scan cannot follow; see the #159 testset")
        nested = normpath(joinpath(dirname(path), call.args[2]))
        isfile(nested) && included_files(nested, seen)
    end
    return seen
end

@testset "quality" begin
    @testset "Aqua" begin
        # ambiguities are skipped: the heavy image/OpenCV dependency stack reports ambiguities in
        # methods this package doesn't own.
        #
        # persistent_tasks is skipped here and runs as its own workflow — it is the only check
        # whose result depends on the network. See test/persistent_tasks.jl, and the testset below
        # that holds the two apart (#159).
        Aqua.test_all(Fromage; ambiguities = false, persistent_tasks = false)
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

    # The offline invariant behind #159. `Aqua.test_all` runs `test_persistent_tasks` by default,
    # and that check is the only one in the suite whose result depends on the network: it generates
    # a temporary package, `Pkg.develop`s this one into it and precompiles the result, which asks
    # Pkg to resolve a fresh environment — a clone of the General registry from GitHub when the
    # depot has none, and a hard error with no network. It also spends ~30 s re-precompiling a
    # dependency stack the suite has already precompiled, and far longer on a cold depot.
    #
    # So it is disabled above and lives in `test/persistent_tasks.jl`, which `runtests.jl` does not
    # include and the PersistentTasks workflow runs on its own. This asserts the split stays split,
    # against every way it can quietly come undone: the keyword going missing, the check being
    # called from a suite file, or the standalone file being hollowed out.
    @testset "the default suite runs no network-backed check (#159)" begin
        for file in included_files(joinpath(@__DIR__, "runtests.jl"))
            @testset "$(relpath(file, @__DIR__))" begin
                ast = Meta.parseall(read(file, String); filename = file)
                @test isempty(calls_to(ast, :test_persistent_tasks))
                for call in calls_to(ast, :test_all)
                    @test passes_keyword(call, :persistent_tasks, false)
                end
            end
        end

        # The other direction, and not a formality: gut `test/persistent_tasks.jl` and everything
        # above stays green, while the workflow that runs it goes on reporting a pass for a file
        # that asserts nothing. That is the failure #220 spent a dozen releases on.
        @testset "the check still lives in test/persistent_tasks.jl" begin
            standalone = joinpath(@__DIR__, "persistent_tasks.jl")
            @test standalone ∉ included_files(joinpath(@__DIR__, "runtests.jl"))
            ast = Meta.parseall(read(standalone, String); filename = standalone)
            @test !isempty(calls_to(ast, :test_persistent_tasks))
        end
    end

    # The structural invariant behind #140 and #141. Both issues came from a parameter
    # having TWO definition sites — the verification stage and the consuming function's kwarg
    # default — with an open `kwargs...` channel between them. Prose and review did not keep that
    # from happening; this does, by failing the moment a parameter appears on one side only.
    #
    # Read as two directions:
    #   forward (#141) — nothing reaches a consumer that the csv did not describe and the gateway
    #                    did not verify;
    #   reverse (#140) — nothing is settable that fails to reach a consumer.
    @testset "every tracking and rectification parameter has exactly one definition site (#140, #141)" begin
        PT = Fromage.PawsomeTracker
        VRuns = Fromage.VerifyRuns
        VRect = Fromage.VerifyRectifications

        @testset "track takes no keyword arguments" begin
            # The whole point of Segment/Tuning. A keyword here would be a second definition of
            # something the gateway already decided, and — because a later splatted keyword
            # silently beats an earlier one — a way to override a verified value with an
            # unverified one.
            for m in methods(PT.track)
                # per-method testset: the invariant is about WHICH method grew a keyword, so a
                # failure has to name it rather than the line the loop sits on
                @testset "$(basename(string(m.file))):$(m.line)" begin
                    @test isempty(Base.kwarg_decl(m))
                end
            end
        end

        @testset "every tracking parameter is a runs.csv column" begin
            # No exceptions: `native_fps` used to be one — probed from the video, settable nowhere —
            # and being unsettable is exactly what made a video that misreports its own rate
            # untrackable. Every field is a column now, so `⊆` is the whole invariant.
            @test Set(fieldnames(PT.Tuning)) ⊆ Set(VRuns.COLUMNS)
            @test Set(fieldnames(PT.Segment)) ⊆ Set(VRuns.COLUMNS)
            # `ResolvedSegment` is a `Segment` whose start has been settled — same parameters, a
            # wider `start_location` union — so the same rule binds it.
            @test Set(fieldnames(PT.ResolvedSegment)) ⊆ Set(VRuns.COLUMNS)

            # `ScaledTuning` is deliberately ABSENT, and that is not an oversight. Its three fields
            # hold `downscale`-scaled values derived from `Tuning`, not tracking parameters, and
            # they are named `width`/`window`/`search` rather than after the columns precisely so
            # that this containment would fail if anyone tried. The rule is "every tracking
            # parameter is a runs.csv column"; a derived value is not one.

            # reverse: everything `tracking_defaults` may set actually lands on a Tuning field
            @test Set(keys(VRuns.DEFAULTS)) ⊆ Set(fieldnames(PT.Tuning))
        end

        @testset "every rectification parameter is a rectifications.csv column" begin
            builders = [Fromage.Rectifications.from_checkerboard, Fromage.Rectifications.from_extrinsic,
                        Fromage.Rectifications.from_matlab, Fromage.Rectifications.from_uniform,
                        PT.ApriltagRectification]
            # width/height are probed from the video; `ntags` is the `apriltags` column under the
            # name the builder gives it. Nothing else is carved out: since #209 the one exception
            # this set used to carry — `rectification_diagnostics`, a caller instruction rather than
            # data — is no longer a builder keyword at all, so every builder keyword is now a
            # rectifications.csv column or a probed frame size, with no third category.
            allowed = Set(VRect.COLUMNS) ∪ Set([:width, :height, :ntags])
            for f in builders, m in methods(f)
                @testset "$(nameof(f)) @ $(basename(string(m.file))):$(m.line)" begin
                    @test Set(Base.kwarg_decl(m)) ⊆ allowed
                end
            end

            # `_rectification` and `_maps` are deliberately NOT in `builders`, and that is not an
            # oversight either. They are the shared tail below the public builders, and they took
            # 13 positional arguments each until the argument-list change; they are keyword-only
            # now, but their keywords include `imgpointss`, `radial_parameters` and a whole
            # `CameraModel` — fitted and derived values that are not csv columns and never will be,
            # so adding them here would fail the containment immediately. Same reasoning as
            # `ScaledTuning` on the tracking side.

            # reverse: everything `rectification_defaults` may set reaches a builder. `apriltags`
            # is spelled `ntags` there, which is exactly the kind of rename this catches.
            # Over ALL methods, not `first(methods(f))`: method order is not specified, and
            # `ApriltagRectification` is a struct, so one of its methods is the positional
            # constructor with no keywords at all.
            consumed = reduce(union, (Set(Base.kwarg_decl(m)) for f in builders for m in methods(f)))
            @test Set(keys(VRect.DEFAULTS)) ⊆ consumed ∪ Set([:apriltags])
        end

        @testset "the rectification dispatchers take a row and nothing else" begin
            # `Rectification(c; kwargs...)` used to splat whatever arrived onward — and the
            # apriltag method forwarded none of it, so even a correct keyword was a silent no-op.
            # #68 replaced the splat with one required keyword, `rectification_diagnostics`; #209
            # took that away too, by moving the diagnostic image to the caller. A dispatcher now
            # takes the row and nothing else, so any keyword at all is a MethodError.
            @test !isempty(methods(Fromage.Rectifications.Rectification))
            for m in methods(Fromage.Rectifications.Rectification)
                @testset "$(basename(string(m.file))):$(m.line)" begin
                    @test isempty(Base.kwarg_decl(m))
                end
            end
        end
    end
end

end
