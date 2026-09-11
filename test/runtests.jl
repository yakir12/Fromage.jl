# The consolidated suite. Two support modules are defined first — `Fixtures` (the synthetic videos
# and the ffprobe readers) and `Harness` (the gateway suites' CSV plumbing) — and then each former
# package's tests run inside their own wrapper module, so their suite-specific names (DATADIR, ART,
# HEADER, …) cannot collide. Testsets nest fine across module boundaries (they use the task's
# dynamic scope, not lexical scope).
using Test

include("fixtures.jl")
include("harness.jl")

"""The Julia minors JET is known-good on, and the single definition site for that list. Kept beside
the suite rather than inside `jet.jl` because the `else` branch below has to name it too."""
const JET_MINORS = (13,)

@testset "Fromage (consolidated)" begin
    include("quality.jl")
    # Only on the minors JET is known-good on — see the header of jet.jl. An ALLOWLIST, not a
    # lower bound: a Julia minor nobody has checked yet runs no JET, which is the point.
    # It holds exactly the minor Test.yml pins, so CI always analyses what it runs.
    #
    # The `else` is not a formality. The allowlist used to be (11, 12) while the matrix said
    # "1", and when "1" rolled from 1.12 to 1.13 those legs silently stopped running JET and
    # stayed green — the analysis vanished and nothing said so. Skipping is still the right
    # behaviour on an unvetted minor; skipping *quietly* is what has to stop, so an off-allowlist
    # run now names itself in the summary and warns.
    if VERSION.major == 1 && VERSION.minor in JET_MINORS
        include("jet.jl")
    else
        @warn """JET did not run: this Julia is not on the allowlist, so the suite says nothing \
                 about type stability or inference errors. Read a pass here accordingly.""" VERSION JET_MINORS
        @testset "JET (SKIPPED — needs Julia 1.$(join(JET_MINORS, " or 1.")), this is $(VERSION))" begin
            @test_skip false
        end
    end
    include("spaces.jl")
    include("shareio.jl")
    include("parsing.jl")
    include("probing.jl")
    include("gateway.jl")
    include("rectifications.jl")
    include("pawsometracker.jl")
    include("apriltag.jl")
    include("apriltag_pipeline.jl")
    include("verifyrectifications.jl")
    include("verifyruns.jl")
    include("fromage.jl")
end
