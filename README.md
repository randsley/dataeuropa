# dataeuropa: Python, Julia and R clients for data.europa.eu

[![CI](https://github.com/randsley/dataeuropa/actions/workflows/ci.yml/badge.svg?branch=main&event=push)](https://github.com/randsley/dataeuropa/actions/workflows/ci.yml)
[![Docs](https://github.com/randsley/dataeuropa/actions/workflows/pages.yml/badge.svg?branch=main&event=push)](https://randsley.github.io/dataeuropa/)
[![PyPI](https://img.shields.io/pypi/v/dataeuropa)](https://pypi.org/project/dataeuropa/)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.24611428.svg)](https://doi.org/10.5281/zenodo.24611428)

**Documentation:** https://randsley.github.io/dataeuropa/ ([Python](https://randsley.github.io/dataeuropa/python/) · [Julia](https://randsley.github.io/dataeuropa/julia/) · [R](https://randsley.github.io/dataeuropa/r/)). Worked examples: [Python](https://randsley.github.io/dataeuropa/python/examples/) · [Julia](https://randsley.github.io/dataeuropa/julia/examples/) · [R](https://randsley.github.io/dataeuropa/r/articles/examples.html).

Three small, equivalent clients for the European data portal (~1.9 M dataset records harvested
from EU institutions and national/regional portals), built on:

| Service | URL |
|---|---|
| Search API (metadata search, facets, scroll) | https://data.europa.eu/api/hub/search |
| Registry API (dataset RDF: Turtle / JSON-LD) | https://data.europa.eu/api/hub/repo |
| SPARQL endpoint (DCAT-AP graph) | https://data.europa.eu/sparql |

## Same verbs in each language

| Task | Python `dataeuropa` | Julia `DataEuropa` | R `dataeuropa` |
|---|---|---|---|
| Search → table | `search_datasets` | `search_datasets` | `de_search_datasets` |
| Raw Search API result | `search` | `search` | `de_search` |
| Bulk retrieval (scroll) | `fetch_datasets` / `iter_datasets` | `fetch_datasets` / `iter_datasets` | `de_fetch_datasets` |
| One dataset | `get_dataset` | `get_dataset` | `de_get_dataset` |
| Files/services of a dataset | `distributions` | `distributions` | `de_distributions` |
| Download a file | `download` | `download_distribution` | `de_download` |
| Response cache | `cache_on`, `cache_off`, `clear_cache` | `cache_on`, `cache_off`, `clear_cache` | `de_cache_on`, `de_cache_off`, `de_clear_cache` |
| Download and read into a table | `load_distribution` | `load_distribution` | `de_load_distribution` |
| Download and read geodata | `load_geodata` | `load_geodata` | `de_load_geodata` |
| Facet ids + counts | `facet_values` | `facet_values` | `de_facet_values` |
| Hit count only | `count` | `count_datasets` | `de_count` |
| Harvested catalogues | `catalogues` | `catalogues` | `de_catalogues` |
| Dataset as RDF | `get_rdf` | `get_rdf` | `de_get_rdf` |
| SPARQL | `sparql` | `sparql` | `de_sparql` |

Convenience filters on all search functions: `country` (ISO-2, e.g. `"pt"`), `catalog`, `format`
(`"CSV"`), `license`, `category` (DCAT-AP theme, e.g. `"ENVI"`), `publisher`, `keywords`, `hvd`
(high-value datasets), plus `sort`, `min_date`/`max_date`/`date_type`, `bbox`.
Values within one filter are OR-ed; different filters are AND-ed.
`bbox` (min lon, min lat, max lon, max lat) matches datasets whose spatial extent overlaps the box;
datasets with no extent (about half the portal) never match, so it suits geodata searches only.

## Quick start

```python
import dataeuropa as de
df = de.search_datasets("water quality", country="pt", format="CSV", limit=5)
dist = de.distributions(df.id[0]); de.download(dist.iloc[0], "data/")
table = de.load_distribution(dist.iloc[0])  # CSV, JSON, XLSX or Parquet straight into a DataFrame
de.facet_values("format", q="flood")          # what formats exist for 'flood'?
de.sparql("SELECT (COUNT(*) AS ?n) WHERE { ?s a <http://www.w3.org/ns/dcat#Dataset> }")
```
```julia
using DataEuropa
df = search_datasets("water quality"; country="pt", format="CSV", limit=5)
dist = distributions(df.id[1]); download_distribution(dist[1, :], "data/")
table = load_distribution(dist[1, :])
```
```r
library(dataeuropa)
df <- de_search_datasets("water quality", country = "pt", format = "CSV", limit = 5)
dist <- de_distributions(df$id[1]); de_download(dist[1, ], "data/")
table <- de_load_distribution(dist[1, ])
```

## Install

Python from PyPI; Julia and R from this repository until they are registered:

```
pip install "dataeuropa[pandas]"                   # Python  (needs requests; pandas optional)
julia -e 'using Pkg; Pkg.develop(path="julia")'    # Julia   (HTTP, JSON3, DataFrames, CSV, SHA, MD5)
R CMD INSTALL r                                    # R       (httr2, jsonlite, openssl)
```

Reading XLSX and Parquet with `load_distribution` needs an optional package: Python
`pip install "dataeuropa[xlsx,parquet]"` (openpyxl, pyarrow); Julia `using XLSX` / `using Parquet2`;
R `install.packages(c("readxl", "arrow"))`. Reading geodata with `load_geodata` (GeoJSON, Shapefile,
GeoPackage, KML, GML, ... through GDAL) needs Python `pip install "dataeuropa[geo]"` (geopandas,
pyogrio); Julia `using GeoDataFrames`; R `install.packages("sf")`.

```
```

## Prior art (searched 23 Nov 2026)

No dedicated Python, Julia or R client for data.europa.eu was found on PyPI, CRAN, the Julia
General registry or GitHub; the three package names were free. Nearby tools, none of which cover it:

- **Python**: `pyeuropeana` (Europeana cultural heritage, a different service); `eurostat`-type
  libraries (Eurostat SDMX); a dltHub source description for data.europa.eu exists but is a
  generic REST-source template, not a client.
- **R**: `ckanr` (generic CKAN; the old CKAN endpoint of the European Data Portal was retired, so
  it no longer fits), `eurostat`, `eurodata` (Eurostat), `eudata` (GISCO geodata), `eurlex`
  (EU Publications Office SPARQL/REST for EU law).
- **Julia**: `EurostatAPI.jl` (Eurostat only).
- **Other**: MCP servers (pipeworx `mcp-data-europa`, APIbase), an Apify actor, and the portal's
  own `api-usage-examples` repository (raw Java/JS/Python/Ruby snippets).

## Caveats

- Many "distributions" are services (WMS/WFS/INSPIRE download), not files; check `format`.
- Some access URLs from publishers are placeholders (e.g. `https://localhost/...`).
- Licence ids are whatever the publisher supplied, so they are not normalised.
- SPARQL text filters over the full graph can take 10 to 40 s; always use `LIMIT`.
- The Search API caps `limit` at 1000 per request; use scroll for more.
- `bbox` drops every dataset without a spatial extent (about 47% of records, and all of some
  national catalogues, e.g. Portugal's), and Europe- or world-wide datasets match any box.
