# Shared test fixtures

The same API responses must give the same tables in Python, Julia and R. This folder holds the
inputs, the expected outputs, and the list of cases that all three test suites run.

| Path | What it is |
|---|---|
| `responses/*.json` | Real API responses recorded by `record.py`, trimmed to stay small |
| `responses/resume.json` | Validators and replies to Range requests, for resuming downloads |
| `responses/formats.json` | Format ids, media types and URLs for format detection |
| `responses/kinds.json` | Distributions to sort into files, services, pages and unusable URLs |
| `files/*` | Sample CSV, JSON, XLSX and Parquet files, written by `make_files.py` (kept byte for byte: see `.gitattributes`) |
| `files/geo/*` | Sample geodata: GeoJSON, zipped shapefiles (one, two, one without `.prj`), a two-layer GeoPackage, KML, KMZ, GML, and a ZIP with no geodata; written by `make_geo_files.py` (needs geopandas) |
| `responses/geo_formats.json` | Format ids, media types and URLs to map to a geodata file type |
| `responses/geo_members.json` | Archive listings to pick the geodata file from |
| `responses/services.json` | Distributions to map to a GDAL feature-service source (`WFS:` or `OAPIF:`) |
| `files/oapif/*.geojson` | The collections served by each language's OGC API Features test server (see below) |
| `responses/edge_cases.json` | Hand-written records for cases the live data rarely shows (missing fields, language fallback, ties, unbound SPARQL variables) |
| `cases.json` | The cases: which input to read, which conversion to run, with which arguments |
| `expected/<case>.json` | Expected output for each case, generated from the Python client |
| `record.py` | Re-records `responses/` from the live API |
| `make_expected.py` | Regenerates `expected/` from the Python client |

Python is the reference implementation, so `expected/` is generated from it. The Python tests
then guard against unintended changes, and the Julia and R tests check that they match it.

## Conversions under test

| `kind` | Python | Julia | R |
|---|---|---|---|
| `summarise` | `summarise_dataset` | `summarise_dataset` | `de_summarise` |
| `distributions` | `_distribution_rows` | `_distribution_table` | `de_distribution_table` |
| `keywords` | `_keywords` | `_keywords` | `de_keywords` |
| `facets` | `_facet_rows` | `_facet_table` | `de_facet_table` |
| `sparql` | `_sparql_rows` | `_sparql_result` | `de_sparql_table` |
| `file_format` | `_file_format` | `_file_format` | `de_file_format` |
| `distribution_kind` | `_distribution_kind` | `_distribution_kind` | `de_distribution_kind` |
| `read_file` | `_read_table` | `_read_table` | `de_read_table` |
| `file_hash` | `_file_hash` | `_file_hash` | `de_file_hash` |
| `range_validator` | `_range_validator` | `_range_validator` | `de_range_validator` |
| `resume_action` | `_resume_action` | `_resume_action` | `de_resume_action` |
| `geo_format` | `_geo_format` | `_geo_format` | `de_geo_format` |
| `geo_member` | `_geo_member` | `_geo_member` | `de_geo_member` |
| `service_source` | `_service_source` | `_service_source` | `de_service_source` |
| `read_geo` | `_read_geodata` + `_geo_summary` | `_read_geodata` + `_geo_summary` (GeoDataFrames extension) | `de_read_geodata` + `de_geo_summary` |

## How results are compared

- Row count and row order must match. Every column in the expected rows must match.
- `null`, `None`, `missing`, `nothing` and `NA` all count as missing.
- Numbers are compared as floating point (R stores counts and sizes as doubles).
- `formats` is a list. R stores it as a comma-separated string, which the R test splits.
- SPARQL ASK results compare as `{"boolean": ...}`; keyword lists as `{"values": [...]}`.
- `read_file` cases also compare column names and order. Dates compare as ISO text.
- `read_geo` cases compare a summary: attribute columns (without geometry), their values, the row
  count (`nrow`), the 2D geometry types, the EPSG code and the bounds (to 1e-9, relative). Cases
  with `columns` compare only those columns' values: KML column sets differ between readers.
  An error compares as `{"error": true}`, whatever the message.

## Running the tests

They run with each language's normal offline tests (see the top-level `CLAUDE.md` or the package
READMEs). R runs them from a source checkout only, because this folder is not part of the R package.

## Changing behaviour

1. Change the Python client.
2. `python fixtures/make_expected.py`, then review the diff in `expected/`.
3. Make Julia and R pass.

To add a case, add an entry to `cases.json` (and, if needed, data to `edge_cases.json`), then run
`make_expected.py`. No test code changes are needed.

To refresh the recorded responses: `python fixtures/record.py`, then `make_expected.py`. The portal's
data changes over time, so expect the diff to be large.

## The OGC API Features test server

Reading feature services is tested offline against a small server, written once per language
(`python/tests/oapif_server.py`, `julia/test/oapif_server.jl`, and in `r/tests/testthat/test-geodata.R`).
It must run in its own process: GDAL blocks the calling thread while it reads. Under a base path:

- the base path itself: a landing page linking to `/collections`;
- `/collections`: one entry per `files/oapif/<name>.geojson`;
- `/collections/<name>`: that collection;
- `/collections/<name>/items?limit=&offset=`: at most 3 features (fewer if `limit` is smaller)
  from `offset`, with a `next` link while more remain, and `numberMatched`;
- anything else: 404 with a JSON body (GDAL also asks for `/api`).

`places` holds 7 points (ids 1 to 7) so reading needs three pages, and a limit of 4 stops after two;
`roads` holds 2 lines.
