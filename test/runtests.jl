# The consolidated suite: each former package's tests run inside their own wrapper module (so
# their helper constants — DATADIR, ART, HEADER, make_video, … — cannot collide), followed by the
# Fromage-level end-to-end test. Testsets nest fine across module boundaries (they use the task's
# dynamic scope, not lexical scope).
using Test

@testset "Fromage (consolidated)" begin
    include("quality.jl")
    include("rectifications.jl")
    include("pawsometracker.jl")
    include("verifycalibrations.jl")
    include("verifyruns.jl")
    include("fromage.jl")
end
