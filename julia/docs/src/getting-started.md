# Getting started

```julia
using DataEuropa
```

## Search

[`search_datasets`](@ref) returns a `DataFrame` with one row per dataset, with the title and
description in your chosen language (falling back to English, then any available language).

```julia
df = search_datasets("air quality"; country="de", format="CSV", limit=20, lang="de")
metadata(df, "count")        # total hits, not just the rows returned
```

Filters: `country` (ISO-2, e.g. `"pt"`), `catalog`, `format` (`"CSV"`), `license`,
`category` (DCAT-AP theme, e.g. `"ENVI"`), `publisher`, `keywords`, `hvd` (high-value datasets),
plus `sort`, `min_date` / `max_date` / `date_type` and `bbox`.
Values within one filter are OR-ed; different filters are AND-ed:

```julia
search_datasets("budget"; country=["pt", "es"], format="CSV")   # (PT or ES) and CSV
```

## Searching by area

```julia
search_datasets("rivers"; bbox=(20, 59.7, 31.6, 70.1))   # min lon, min lat, max lon, max lat
```

!!! note "How `bbox` matches"
    A dataset matches when its spatial extent overlaps the box, so datasets that cover all of
    Europe or the world match any box. Datasets without a spatial extent never match: that is
    about half the portal, including whole national catalogues (none of Portugal's 21,000 datasets
    has one). Combine `bbox` with `country` with care.

## Counting and facets

```julia
count_datasets("flood"; country="nl")       # hits only, no records transferred
facet_values("format"; q="flood")           # which formats exist, with counts
facet_values("country"; top=10)
```

## More than 1,000 results

The Search API returns at most 1,000 records per request. [`fetch_datasets`](@ref) and
[`iter_datasets`](@ref) page through larger result sets with the scroll API:

```julia
df = fetch_datasets("energy"; country="fr", max_results=5000)

for record in iter_datasets("energy"; country="fr")   # raw records, streamed
    # ...
end
```

## Getting the data

```julia
dist = distributions(dataset_id)                 # files and services of one dataset
path = download_distribution(dist[1, :], "data/")
```

!!! warning "Not every distribution is a file"
    Many distributions are services (WMS, WFS, INSPIRE download services) rather than files,
    and some publisher URLs are placeholders such as `https://localhost/...`.
    Check the `format` column before downloading.

## Reading a file into a table

```julia
dist = distributions(dataset_id)
df = load_distribution(dist[1, :])                     # format detected from the row
df = load_distribution(url; format="csv")              # or say which
using XLSX;     df = load_distribution(url; sheet="Data")   # XLSX sheet by name or 1-based index
using Parquet2; df = load_distribution(parquet_url)
```

Reads CSV (CSV.jl) and JSON; XLSX once `XLSX` is loaded and Parquet once `Parquet2` is loaded.
The format comes from the row's format id, then its media type, then the URL's file extension.

- **CSV**: the delimiter (`,` `;` tab `|`) is detected from the header line; text is read as
  UTF-8, falling back to Latin-1; only empty cells count as missing. Decimal commas (`12,5`) and
  dates stay text.
- **JSON**: an array of objects, or an object holding exactly one such array.

It refuses, with a clear error, services (WMS, WFS, APIs), compressed archives (use
`download_distribution` and unpack them), and HTML pages that some publishers serve instead of
the file.

## Metadata as RDF, and SPARQL

```julia
ttl = get_rdf(dataset_id)                         # Turtle; get_rdf(id, "jsonld") for JSON-LD
sparql("""
    SELECT ?format (COUNT(*) AS ?n) WHERE {
      ?d a <http://www.w3.org/ns/dcat#Distribution> ; <http://purl.org/dc/terms/format> ?format
    } GROUP BY ?format ORDER BY DESC(?n) LIMIT 10
""")
```

SPARQL queries that filter text across the whole graph can take 10 to 40 seconds.
Always use `LIMIT`.

## Settings

| Environment variable | Default | Effect |
|:--|:--|:--|
| `DATAEUROPA_TIMEOUT` | `60` | request timeout in seconds |

Requests that fail with HTTP 429 or 5xx are retried with backoff.
