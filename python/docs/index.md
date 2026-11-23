# dataeuropa

Python client for [data.europa.eu](https://data.europa.eu), the European open data portal
(about 1.9 million dataset records harvested from EU institutions and national and regional portals).

It wraps three public services, none of which needs an API key:

| Service | Used for |
|---|---|
| Search API | metadata search, facets, bulk retrieval (scroll) |
| Registry API | dataset metadata as RDF (Turtle, JSON-LD) |
| SPARQL endpoint | queries over the whole DCAT-AP graph |

Equivalent clients with the same verbs exist for [Julia](https://randsley.github.io/dataeuropa/julia/) and [R](https://randsley.github.io/dataeuropa/r/).

## Install

```bash
pip install "dataeuropa[pandas] @ git+https://github.com/randsley/dataeuropa#subdirectory=python"
```

`requests` is the only required dependency. With `pandas` installed, table-returning functions
give a `DataFrame`; without it they return a list of dicts.

## Thirty-second tour

```python
import dataeuropa as de

df = de.search_datasets("water quality", country="pt", format="CSV", limit=5)
dist = de.distributions(df.id[0])
de.download(dist.iloc[0], "data/")
```

Next: [Getting started](getting-started.md), or the full [reference](reference.md).
