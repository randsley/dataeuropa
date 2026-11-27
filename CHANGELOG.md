# Changelog

All three packages (Python `dataeuropa`, Julia `DataEuropa`, R `dataeuropa`) share one version
number and one changelog, because every change lands in all three.

## 0.1.1 (2026-11-27)

### Changed
- `download` (Julia: `download_distribution`; R: `de_download`) needs a destination: a file path,
  or a directory to save the file in under its own name. It used to default to the working
  directory; now nothing is written anywhere you did not name. Without `dest` it stops with an
  error that says so. Pass `"."` for the old behaviour.

### Fixed
- The Python package's page on PyPI showed a from-source install command; it now shows
  `pip install "dataeuropa[pandas]"`.

## 0.1.0 (2026-11-27)

First release.

### Search and metadata
- `search_datasets` and `search`: full-text search with filters for country, catalogue, format,
  licence, theme, publisher, keywords, high-value datasets, dates and a bounding box. The box is
  checked before the request, because the API ignores partial boxes.
- `fetch_datasets` / `iter_datasets`: more than 1,000 results through the API's scroll mode.
- `count` (Julia: `count_datasets`) and `facet_values`: counts and the values of a facet
  (country, format, theme, ...) without fetching records.
- `get_dataset`, `catalogues`, and `get_rdf` for the Registry's Turtle or JSON-LD.
- `sparql`: queries to the portal's SPARQL endpoint, as a data frame.
- Titles and descriptions in a chosen language, falling back to English, then to any language.

### Files and data
- `distributions`: a dataset's files and services, one row each, with a `kind` column (file,
  service, page, none, unknown) and `files_only`. Junk and look-alike format ids (`.csv`,
  Cyrillic `сsv`) are recognised.
- `download` (Julia: `download_distribution`): checks the portal's checksum (MD5, SHA-1,
  SHA-256) when there is one, resumes interrupted downloads, and can refuse files over a size
  limit.
- `load_distribution`: a distribution straight into a data frame (CSV, JSON, XLSX, Parquet).
  Refuses services, archives and HTML pages served instead of data.
- `load_geodata`: geodata into a GeoDataFrame (Python), an sf data frame (R) or a GeoDataFrames.jl
  table (Julia), through GDAL. Reads GeoJSON, shapefiles (zipped), GeoPackage, KML/KMZ and GML;
  picks layers; keeps or reprojects the coordinate system; refuses files over 200 MB unless asked.
  Also reads WFS and OGC API Features services (at most 10,000 features unless asked). WFS layer
  names match without their namespace prefix.

### Other
- Opt-in response cache with a time limit (`cache_on`, `cache_off`, `clear_cache`).
- Retries with backoff on 429 and 5xx responses; timeout from `DATAEUROPA_TIMEOUT`.
- Shared conformance tests: the same recorded API responses must give the same tables in all
  three languages.
- Documentation sites with a getting-started guide, worked examples and a reference for each
  language: https://randsley.github.io/dataeuropa/
