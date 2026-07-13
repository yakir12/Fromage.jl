using Fromage
using Documenter
using DocumenterVitepress

makedocs(;
    authors = "Yakir Gagnon <12.yakir@gmail.com> and contributors",
    sitename = "Fromage.jl",
    format = DocumenterVitepress.MarkdownVitepress(
        repo = "github.com/yakir12/Fromage.jl",
        devbranch = "main",
        devurl = "dev",
    ),
    pages = [
        "Home" => "index.md",
        "Get started" => "get-started.md",
        "Prepare your data" => [
            "The data folder" => "data-folder.md",
            "runs.csv" => "runs.md",
            "calibs.csv" => "calibs.md",
        ],
        "Your results" => "results.md",
        "Help & troubleshooting" => "help.md",
    ],
)

DocumenterVitepress.deploydocs(;
    repo = "github.com/yakir12/Fromage.jl",
    target = joinpath(@__DIR__, "build"),
    branch = "gh-pages",
    devbranch = "main",
    push_preview = true,
)
