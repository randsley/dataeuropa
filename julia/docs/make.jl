using Documenter, DataEuropa

makedocs(
    sitename = "DataEuropa.jl",
    modules = [DataEuropa],
    repo = Remotes.GitHub("randsley", "dataeuropa"),
    format = Documenter.HTML(
        canonical = "https://randsley.github.io/dataeuropa/julia/",
        edit_link = "main",
        prettyurls = get(ENV, "CI", "false") == "true",
    ),
    pages = [
        "Home" => "index.md",
        "Getting started" => "getting-started.md",
        "Reference" => "reference.md",
    ],
)
