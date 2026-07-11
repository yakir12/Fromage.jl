# JET static analysis: abstract interpretation of the whole package, reporting only what
# originates in Fromage's own modules (dependencies produce plenty of noise of their own).
# Included from runtests.jl only on the pinned Julia minor: JET couples to compiler internals,
# so a new Julia release must not be able to break the suite through JET.
using JET: JET
using Fromage: Fromage

@testset "JET" begin
    JET.test_package(Fromage; target_modules = (Fromage,))
end
