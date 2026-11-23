# DataEuropa.jl

Julia client for [data.europa.eu](https://data.europa.eu), the European open data portal
(about 1.9 million dataset records harvested from EU institutions and national and regional portals).

It wraps three public services, none of which needs an API key:

| Service | Used for |
|:--|:--|
| Search API | metadata search, facets, bulk retrieval (scroll) |
| Registry API | dataset metadata as RDF (Turtle, JSON-LD) |
| SPARQL endpoint | queries over the whole DCAT-AP graph |

Equivalent clients with the same verbs exist for [Python](https://randsley.github.io/dataeuropa/python/)
and [R](https://randsley.github.io/dataeuropa/r/).

## Install

```julia
using Pkg
Pkg.add(url="https://github.com/randsley/dataeuropa", subdir="julia")
```

## Thirty-second tour

```julia
using DataEuropa

df = search_datasets("water quality"; country="pt", format="CSV", limit=5)
dist = distributions(df.id[1])
download_distribution(dist[1, :], "data/")
```

Next: [Getting started](getting-started.md), or the full [Reference](reference.md).
