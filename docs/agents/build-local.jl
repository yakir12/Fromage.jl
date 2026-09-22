# Build the existing docs without ever evaluating their deployment expression.
# Reject an unexpected entry-point shape before evaluating any part of it.
"""Select imports and the build call from the current docs entry point; reject structural drift."""
function local_docs_expressions(file)
    parsed = Meta.parseall(read(file, String); filename = file)
    expressions = filter(x -> !(x isa LineNumberNode), parsed.args)
    length(expressions) == 5 || error("docs/make.jl changed; review the build-only adapter")
    expected_imports = [:(using Fromage), :(using Documenter), :(using DocumenterVitepress)]
    expressions[1:3] == expected_imports || error("Unexpected documentation imports")
    build, deploy = expressions[4:5]
    Meta.isexpr(build, :call) && build.args[1] == :makedocs || error("Expected makedocs")
    Meta.isexpr(deploy, :call) && deploy.args[1] == :(DocumenterVitepress.deploydocs) ||
        error("Expected separate deploydocs call")
    return expressions[1:4]
end

"""Build documentation without its separate deployment call, or validate selection with `--check`."""
function build_local_docs(args)
    all(==("--check"), args) || error("Only --check is supported")
    docs_dir = dirname(@__DIR__)
    file = joinpath(docs_dir, "make.jl")
    expressions = local_docs_expressions(file)
    if "--check" in args
        println("Build-only adapter: three imports and makedocs; deploydocs excluded")
        return
    end
    # include_string retains make.jl's filename for source-relative doc settings.
    source = join((string(ex) for ex in expressions), "\n")
    cd(docs_dir) do
        Base.include_string(Module(:LocalDocs), source, file)
    end
    return
end

build_local_docs(ARGS)
