# Getting started

```python
import dataeuropa as de
```

## Search

`search_datasets` returns one row per dataset, with the title and description in your chosen
language (falling back to English, then any available language).

```python
df = de.search_datasets("air quality", country="de", format="CSV", limit=20, lang="de")
df.attrs["count"]        # total hits, not just the rows returned
```

Filters: `country` (ISO-2, e.g. `"pt"`), `catalog`, `format` (`"CSV"`), `license`,
`category` (DCAT-AP theme, e.g. `"ENVI"`), `publisher`, `keywords`, `hvd` (high-value datasets),
plus `sort`, `min_date` / `max_date` / `date_type` and `bbox`.
Values within one filter are OR-ed; different filters are AND-ed:

```python
de.search_datasets("budget", country=["pt", "es"], format="CSV")   # (PT or ES) and CSV
```

## Counting and facets

```python
de.count("flood", country="nl")              # hits only, no records transferred
de.facet_values("format", q="flood")         # which formats exist, with counts
de.facet_values("country", top=10)
```

## More than 1,000 results

The Search API returns at most 1,000 records per request. `fetch_datasets` and `iter_datasets`
page through larger result sets with the scroll API:

```python
df = de.fetch_datasets("energy", country="fr", max_results=5000)

for record in de.iter_datasets("energy", country="fr"):   # raw records, streamed
    ...
```

## Getting the data

```python
dist = de.distributions(dataset_id)      # files and services of one dataset
path = de.download(dist.iloc[0], "data/")
```

!!! warning "Not every distribution is a file"
    Many distributions are services (WMS, WFS, INSPIRE download services) rather than files,
    and some publisher URLs are placeholders such as `https://localhost/...`.
    Check the `format` column before downloading.

## Metadata as RDF, and SPARQL

```python
ttl = de.get_rdf(dataset_id)              # Turtle; fmt="jsonld" for JSON-LD
de.sparql("""
    SELECT ?format (COUNT(*) AS ?n) WHERE {
      ?d a <http://www.w3.org/ns/dcat#Distribution> ; <http://purl.org/dc/terms/format> ?format
    } GROUP BY ?format ORDER BY DESC(?n) LIMIT 10
""")
```

SPARQL queries that filter text across the whole graph can take 10 to 40 seconds.
Always use `LIMIT`.

## Settings

| Environment variable | Default | Effect |
|---|---|---|
| `DATAEUROPA_TIMEOUT` | `60` | request timeout in seconds |

Requests that fail with HTTP 429 or 5xx are retried with backoff.
