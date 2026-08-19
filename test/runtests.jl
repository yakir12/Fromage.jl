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
    # Only on the pinned CI minor — see the header of jet.jl.
    VERSION.major == 1 && VERSION.minor == 11 && include("jet.jl")
    include("parsing.jl")
    include("probing.jl")
    include("rectifications.jl")
    include("pawsometracker.jl")
    include("apriltag.jl")
    include("verifyrectifications.jl")
    include("verifyruns.jl")
    include("fromage.jl")
end
