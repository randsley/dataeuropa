# Plan: geodata loaders

Status: proposal, not started. Needs decisions on the open questions at the end before work begins.

## Why

Geodata is a large share of the portal's files. Counts of distributions by format id (live, November
2026; services such as WMS/WFS left out):

| Format | Distributions | Notes |
|---|---:|---|
| GeoJSON | 40,400 | plain JSON; easiest |
| KML | 28,000 | |
| Shapefile | about 39,700 | under several ids: `SHP`, `esri shapefile (shp)`, `shapefile`, `shape`, `shapefile (zip)`; nearly always zipped |
| GML | 12,500 | plus `XPlanGML` (2,900) and zipped GML `GMZ` |
| GeoPackage | 8,100 | `GPKG`, `application/geopackage+sqlite3` |
| MapInfo TAB | 5,600 | usually zipped, several files |
| Esri File Geodatabase | 3,700 | a folder, zipped |
| GPX, KMZ, DXF | 1,100, 1,100, 900 | |

Today `load_distribution` reads none of these: it reads tables, and refuses ZIP archives.

## What to build

One new verb in each language, keeping `load_distribution` for plain tables:

| Python | Julia | R |
|---|---|---|
| `load_geodata(url_or_row, *, layer=None, crs=None)` → `GeoDataFrame` | `load_geodata(x; layer=nothing, crs=nothing)` → `DataFrame` with a geometry column | `de_load_geodata(x, layer = NULL, crs = NULL)` → `sf` |

Behaviour, the same in all three:

1. **Format detection**: reuse `_file_format` with a new `"geo"` group (GeoJSON, KML, KMZ, GML,
   GPKG, Shapefile, GPX, TAB, FileGDB), including the many Shapefile spellings above.
2. **Archives**: unlike `load_distribution`, unpack ZIP files. Inside, find the one dataset to
   read: a single `.shp` (with its `.dbf`, `.shx`, `.prj`), `.gpkg`, `.gdb` folder, `.geojson` or
   `.tab`. Several candidates: error that lists them, so the caller picks one with `layer`.
   Archives inside archives: error.
3. **Layers**: GeoPackage and FileGDB can hold several layers; `layer` picks one by name or index;
   default the first, with a message if there were more.
4. **Coordinate systems**: keep the source CRS. `crs="EPSG:4326"` reprojects. A missing `.prj`
   leaves the CRS unset, with a warning rather than a guess.
5. **Refusals**: services, pages and `none` kinds as today; files over a size limit only with
   an explicit opt-in (geodata files are often hundreds of MB).
6. **Reading is done by GDAL** in all three languages (through the packages below), so formats
   and edge cases behave alike.

## Packages (need approval)

All three are heavy because they bring GDAL, so they stay optional, like XLSX and Parquet:

| Language | Package | How it is optional | Notes |
|---|---|---|---|
| Python | `geopandas` with `pyogrio` | extra `dataeuropa[geo]` | wheels include GDAL; no system install |
| R | `sf` | `Suggests`, checked with `requireNamespace` | needs system GDAL/GEOS/PROJ on Linux; CI's `setup-r-dependencies` installs them |
| Julia | `GeoDataFrames.jl` (ArchGDAL, GDAL_jll) | weak dependency + package extension, like XLSX/Parquet2 | large first install and precompile |

## Tests

- **Shared fixtures**: small files written by a script (like `fixtures/make_files.py`): a GeoJSON,
  a zipped Shapefile with `.prj`, a GeoPackage with two layers, a KML, a ZIP holding two
  shapefiles (for the "pick a layer" error).
- **Conformance**: compare attribute columns, row count, geometry type, the CRS as an EPSG code,
  and geometry as WKT rounded to 6 decimals (exact coordinates differ slightly between GDAL builds).
- **Live**: one GeoJSON and one zipped Shapefile from the portal, kept small.
- **CI**: install the geo packages in each job; expect slower first runs (cache them).

## Later: reading services

The roadmap's future extension for services fits here. WFS `GetFeature` (with
`outputFormat=application/json`) and OGC API Features (`/collections/{id}/items`) return GeoJSON,
so `load_geodata` could accept those distributions too, with paging and a feature limit. WMS and
WMTS return images and stay out of scope.

## Open questions

1. Approve the three packages (geopandas + pyogrio, sf, GeoDataFrames.jl) as optional?
2. A separate `load_geodata` verb (proposed), or a `geo=True` option on `load_distribution`?
3. Default size limit before asking for an opt-in (proposal: 200 MB)?
4. Order: files first (GeoJSON, Shapefile, GeoPackage, KML), then services as a second step?
