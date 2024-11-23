using Fromage
using Documenter

DocMeta.setdocmeta!(Fromage, :DocTestSetup, :(using Fromage); recursive=true)

makedocs(;
    modules=[Fromage],
    authors="Yakir Gagnon <12.yakir@gmail.com> and contributors",
    sitename="Fromage.jl",
    format=Documenter.HTML(;
        canonical="https://yakir12.github.io/Fromage.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/yakir12/Fromage.jl",
    devbranch="main",
)
