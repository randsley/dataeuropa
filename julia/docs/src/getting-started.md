# Getting started

```julia
using DataEuropa
```

For complete tasks from search to result, see the [worked examples](examples.md).

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
    The `kind` column sorts them: `file`, `service`, `page` (a web page), `none` (no usable
    URL) or `unknown`. `distributions(dataset_id; files_only=true)` keeps only files.

When the portal lists a checksum for the file (the `checksum` and `checksum_algorithm`
columns; MD5, SHA-1 or SHA-256), the download is checked against it. A mismatch deletes the
file and raises an error; `verify=false` skips the check. Only about 3% of distributions
have a checksum. `byte_size` is not checked, because it is often a placeholder (0, 1, 1024).

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

## Reading geodata

```julia
using GeoDataFrames                                       # loads the geodata reader
dist = distributions(dataset_id; files_only=true)
df = load_geodata(dist[1, :])                             # GeoJSON, zipped Shapefile, GeoPackage, KML, GML, ...
df = load_geodata(url; layer="wells")                     # a layer of a GeoPackage, or a file in a ZIP
df = load_geodata(url; crs="EPSG:4326")                   # reproject
df = load_geodata(url; max_mb=nothing)                    # files over 200 MB are refused by default
```

GDAL (through GeoDataFrames.jl) does the reading, so any vector format it knows works. The result
is a `DataFrame` with a `geometry` column, as GeoDataFrames.jl makes them; the coordinate reference
system is in its `"crs"` metadata.

- **ZIP archives** (how shapefiles are published) are opened in place. Inside, the one geodata
  file is read; if there are several, `layer` picks one by file name, otherwise the error lists
  them.
- **Layers**: `layer` picks one by name or 1-based position; by default the first, with a note
  when there are more.
- **Coordinate systems**: the source CRS is kept; `crs` reprojects. A file without one (a
  shapefile without `.prj`) is read as stored, with a warning.
- **Size**: files over `max_mb` megabytes (default 200) are not downloaded.
  `download_distribution` takes the same limit as `max_bytes`.

### Feature services (WFS, OGC API Features)

```julia
df = load_geodata(row)                                    # a WFS or OGC API Features distribution
df = load_geodata(row; layer="parcels")                   # a feature type or collection
df = load_geodata(row; max_features=nothing)              # all features (default: the first 10,000)
```

`load_geodata` also reads WFS (URLs with `service=WFS`, WFS format ids) and OGC API Features
(collection or landing-page URLs, `OGCFEAT`). GDAL pages through the results; each feature type
or collection is a layer. It reads at most `max_features` features, with a warning when there
are more. Other services (WMS, WMTS: images; INSPIRE Atom feeds) and web pages are refused.

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

## Caching responses

```julia
cache_on()                                  # this session; or set DATAEUROPA_CACHE=1
cache_on("cache/"; ttl=3600)
cache_off()
clear_cache()                               # delete cached responses
```

The cache is off by default. When on, it keeps dataset records, the catalogue list, and
searches with `limit` 0 (facet values and counts) on disk for a day, so repeated lookups do not
go back to the portal. Searches that return records, SPARQL and file downloads are never cached.

## Interrupted downloads

Files are written as `<file>.part` and renamed when complete. Calling `download_distribution` again with the
same URL and destination continues an interrupted download where it stopped, when the server
supports it (most file hosts do). A file that changed on the server meanwhile is downloaded again
from the start. `resume=false` always starts from the start.

## Settings

| Environment variable | Default | Effect |
|:--|:--|:--|
| `DATAEUROPA_TIMEOUT` | `60` | request timeout in seconds |
| `DATAEUROPA_CACHE` | off | `1` turns the response cache on |
| `DATAEUROPA_CACHE_DIR` | the operating system's cache folder | where cached responses go |
| `DATAEUROPA_CACHE_TTL` | `86400` (one day) | how long a cached response stays valid, in seconds |

Requests that fail with HTTP 429 or 5xx are retried with backoff.
