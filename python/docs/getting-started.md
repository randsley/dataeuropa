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

## Searching by area

```python
de.search_datasets("rivers", bbox=(20, 59.7, 31.6, 70.1))   # min lon, min lat, max lon, max lat
```

!!! note "How `bbox` matches"
    A dataset matches when its spatial extent overlaps the box, so datasets that cover all of
    Europe or the world match any box. Datasets without a spatial extent never match: that is
    about half the portal, including whole national catalogues (none of Portugal's 21,000 datasets
    has one). Combine `bbox` with `country` with care.

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
    The `kind` column sorts them: `file`, `service`, `page` (a web page), `none` (no usable
    URL) or `unknown`. `de.distributions(dataset_id, files_only=True)` keeps only files.

When the portal lists a checksum for the file (the `checksum` and `checksum_algorithm`
columns; MD5, SHA-1 or SHA-256), the download is checked against it. A mismatch deletes the
file and raises an error; `verify=False` skips the check. Only about 3% of distributions
have a checksum. `byte_size` is not checked, because it is often a placeholder (0, 1, 1024).

## Reading a file into a table

```python
dist = de.distributions(dataset_id)
df = de.load_distribution(dist.iloc[0])                 # format detected from the row
df = de.load_distribution(url, format="csv")            # or say which
df = de.load_distribution(url, sheet="Data")            # XLSX sheet by name or 0-based index
```

Reads CSV and JSON with pandas, XLSX with openpyxl (`pip install "dataeuropa[xlsx]"`) and
Parquet with pyarrow (`pip install "dataeuropa[parquet]"`). The format comes from the row's format
id, then its media type, then the URL's file extension.

- **CSV**: the delimiter (`,` `;` tab `|`) is detected from the header line; text is read as
  UTF-8, falling back to Latin-1; only empty cells count as missing. Decimal commas (`12,5`) and
  dates stay text.
- **JSON**: an array of objects, or an object holding exactly one such array.

It refuses, with a clear error, services (WMS, WFS, APIs), compressed archives (use `download`
and unpack them), and HTML pages that some publishers serve instead of the file.

## Reading geodata

```python
dist = de.distributions(dataset_id, files_only=True)
gdf = de.load_geodata(dist.iloc[0])                     # GeoJSON, zipped Shapefile, GeoPackage, KML, GML, ...
gdf = de.load_geodata(url, layer="wells")               # a layer of a GeoPackage, or a file in a ZIP
gdf = de.load_geodata(url, crs="EPSG:4326")             # reproject
gdf = de.load_geodata(url, max_mb=None)                 # files over 200 MB are refused by default
```

Needs geopandas and pyogrio (`pip install "dataeuropa[geo]"`); GDAL does the reading, so any
vector format it knows works. The result is a GeoDataFrame whose geometry column is `geometry`.

- **ZIP archives** (how shapefiles are published) are opened in place. Inside, the one geodata
  file is read; if there are several, `layer` picks one by file name, otherwise the error lists
  them.
- **Layers**: `layer` picks one by name or 0-based position; by default the first, with a warning
  when there are more.
- **Coordinate systems**: the source CRS is kept; `crs` reprojects. A file without one (a
  shapefile without `.prj`) is read as stored, with a warning.
- **Size**: files over `max_mb` megabytes (default 200) are not downloaded. `download` takes the
  same limit as `max_bytes`.

Services (WMS, WFS) and web pages are refused; reading WFS and OGC API Features is planned.

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

## Caching responses

```python
de.cache_on()                                  # this session; or set DATAEUROPA_CACHE=1
de.cache_on(dir="cache/", ttl=3600)
de.cache_off()
de.clear_cache()                               # delete cached responses
```

The cache is off by default. When on, it keeps dataset records, the catalogue list, and
searches with `limit` 0 (facet values and counts) on disk for a day, so repeated lookups do not
go back to the portal. Searches that return records, SPARQL and file downloads are never cached.

## Interrupted downloads

Files are written as `<file>.part` and renamed when complete. Calling `download` again with the
same URL and destination continues an interrupted download where it stopped, when the server
supports it (most file hosts do). A file that changed on the server meanwhile is downloaded again
from the start. `resume=False` always starts from the start.

## Settings

| Environment variable | Default | Effect |
|---|---|---|
| `DATAEUROPA_TIMEOUT` | `60` | request timeout in seconds |
| `DATAEUROPA_CACHE` | off | `1` turns the response cache on |
| `DATAEUROPA_CACHE_DIR` | the operating system's cache folder | where cached responses go |
| `DATAEUROPA_CACHE_TTL` | `86400` (one day) | how long a cached response stays valid, in seconds |

Requests that fail with HTTP 429 or 5xx are retried with backoff.
