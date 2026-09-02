# The consolidated suite. Two support modules are defined first — `Fixtures` (the synthetic videos
# and the ffprobe readers) and `Harness` (the gateway suites' CSV plumbing) — and then each former
# package's tests run inside their own wrapper module, so their suite-specific names (DATADIR, ART,
# HEADER, …) cannot collide. Testsets nest fine across module boundaries (they use the task's
# dynamic scope, not lexical scope).
using Test

include("fixtures.jl")
include("harness.jl")

@testset "Fromage (consolidated)" begin
    include("quality.jl")
    # Only on the minors JET is known-good on — see the header of jet.jl. An ALLOWLIST, not a
    # lower bound: a Julia minor nobody has checked yet drops off it and runs no JET at all, which
    # is the point. Both entries are in the CI matrix already ("1.11" and "1", the latter being
    # 1.12 today), so this costs no extra job — it just stops 1.12 from skipping the analysis.
    VERSION.major == 1 && VERSION.minor in (11, 12) && include("jet.jl")
    include("shareio.jl")
    include("parsing.jl")
    include("probing.jl")
    include("rectifications.jl")
    include("pawsometracker.jl")
    include("apriltag.jl")
    include("apriltag_pipeline.jl")
    include("verifyrectifications.jl")
    include("verifyruns.jl")
    include("fromage.jl")
end
