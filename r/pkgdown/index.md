# dataeuropa

R client for [data.europa.eu](https://data.europa.eu), the European open data portal
(about 1.9 million dataset records harvested from EU institutions and national and regional portals).

It wraps three public services, none of which needs an API key:

| Service | Used for |
|:--|:--|
| Search API | metadata search, facets, bulk retrieval (scroll) |
| Registry API | dataset metadata as RDF (Turtle, JSON-LD) |
| SPARQL endpoint | queries over the whole DCAT-AP graph |

Equivalent clients with the same verbs exist for [Python](https://randsley.github.io/dataeuropa/python/)
and [Julia](https://randsley.github.io/dataeuropa/julia/).

## Install

```r
# install.packages("remotes")
remotes::install_github("randsley/dataeuropa", subdir = "r")
```

Requires R 4.1 or later. Dependencies: httr2 and jsonlite. Results are base data frames.

## Thirty-second tour

```r
library(dataeuropa)

df <- de_search_datasets("water quality", country = "pt", format = "CSV", limit = 5)
dist <- de_distributions(df$id[1])
de_download(dist[1, ], "data/")
```

Next: [Getting started](articles/getting-started.html), or the full [reference](reference/index.html).
