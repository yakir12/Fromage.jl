# Aqua's persistent-task check, split out of the default suite because it is the one check whose
# result depends on the network (#159).
#
# NOT part of the test suite: `runtests.jl` does not include this, and `test/quality.jl` asserts
# both that it doesn't and that this file still calls the check. `Aqua.test_all` would run it as a
# matter of course — it is on by default — but the check generates a temporary package,
# `Pkg.develop`s this one into it and precompiles the result. That asks Pkg to resolve a fresh
# environment, which downloads the General registry and clones it from GitHub when the depot has
# none. With no registry and no network that is a hard error; with a registry but no network it
# still resolves versions the depot may not hold, and passes only when it happens to. Either way
# the documented test command was at the mercy of a service with nothing to do with this code.
#
# The check itself is worth keeping: a package that leaves a Task running after load blocks
# precompilation of everything that depends on it, and nothing else in the suite would notice.
# So it runs here instead, on its own:
#
#     julia --project=test test/persistent_tasks.jl
#
# or, on CI, as the PersistentTasks workflow — which deliberately does NOT gate a release, for the
# reason RELEASING.md gives for Lint. A bare script, like `test/tolerance_residuals.jl`, the other
# file `runtests.jl` does not include: nothing includes this, so there are no names to keep out of
# anyone's way.

using Test
using Aqua
using Fromage

@testset "Aqua persistent tasks" begin
    Aqua.test_persistent_tasks(Fromage)
end
