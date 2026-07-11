# The consolidated suite: each former package's tests run inside their own wrapper module (so
# their helper constants — DATADIR, ART, HEADER, make_video, … — cannot collide), followed by the
# Fromage-level end-to-end test. Testsets nest fine across module boundaries (they use the task's
# dynamic scope, not lexical scope).
using Test

@testset "Fromage (consolidated)" begin
    include("quality.jl")
    # Only on the pinned CI minor — see the header of jet.jl.
    VERSION.major == 1 && VERSION.minor == 11 && include("jet.jl")
    include("parsing.jl")
    include("rectifications.jl")
    include("pawsometracker.jl")
    include("apriltag.jl")
    include("verifyrectifications.jl")
    include("verifyruns.jl")
    include("fromage.jl")
end
