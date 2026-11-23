# Roadmap

Goal: make this repo the default way to get from "I need EU open data on X" to a DataFrame, in Python, Julia and R, with identical behaviour in all three.

Suggested order: phase 1, then `load_distribution` and caching from phase 2, then docs and a first release (phase 4), then phases 3 and 5. A first release with solid tests and a one-line "search to DataFrame" workflow is worth more than a larger feature set.

## 1. Make it trustworthy
- [x] CI on GitHub Actions for all three languages: offline tests on every push, live tests on a weekly schedule.
- [x] Recorded fixtures (real API responses saved as JSON) for the offline tests: `fixtures/`.
- [x] Shared conformance suite: the same fixtures must produce the same table in Python, Julia and R (17 cases in `fixtures/cases.json`).
- [x] API-drift check: compare the live API against the published OpenAPI spec (`https://data.europa.eu/api/hub/search/openapi.yaml`) on a schedule. `tools/check_api.py`, weekly in `.github/workflows/api-check.yml`; the spec does not describe responses, so response fields are checked against live data.
- [x] Run Julia `Pkg.test()` on a normal machine (the registry error was a wrong `Test` UUID in `julia/test/Project.toml`; fixed).
- [x] Verify that `bbox` actually filters results. It does (overlap match), but drops datasets without a spatial extent (~47%); now validated client-side and documented.

## 2. Close the "found it, now give me the data" gap
- [x] `load_distribution()`: download and read straight into a DataFrame (CSV, JSON, XLSX, Parquet). Refuses services, archives and HTML pages; 9 shared cases in `fixtures/`.
- [x] Verify downloads against the API's checksum (MD5, SHA-1 or SHA-256; on about 3% of distributions). `byte_size` is not checked: in a sample, 20 of 37 sizes were wrong, mostly placeholders (0, 1, 1024).
- [x] Resumable downloads (Range with If-Range, so a changed file restarts) and an opt-in on-disk cache with a time limit (dataset records, catalogues, `limit=0` searches).
- [x] Skip service entries when a file is wanted: a `kind` column (file, service, page, none, unknown) and `files_only`. Recognises INSPIRE download services, OGC API Features, Esri REST, feeds, OGC queries in URLs, web pages, localhost placeholders, and Cyrillic look-alike letters in format ids (`сsv`).
  - [x] Extension: read feature services instead of skipping them (WFS and OGC API Features, through `load_geodata`; see below). WMS/WMTS are images and stay out of scope; INSPIRE Atom feeds (lists of files) are not read yet.
- [x] Geodata loaders, step 1 (files): `load_geodata` into a GeoDataFrame, `sf` or a GeoDataFrames.jl table, through GDAL. Opens ZIP archives in place, picks layers, keeps or reprojects the CRS, refuses files over 200 MB unless asked. Plan and decisions: [`geodata-plan.md`](geodata-plan.md).
- [x] Geodata loaders, step 2 (services): `load_geodata` reads WFS and OGC API Features through GDAL, which pages through the results; feature types and collections are layers; at most 10,000 features by default (`max_features`). Offline tests use a small OGC API Features server in each language.

## 3. Use more of the portal
- [ ] Metadata Quality Assurance (MQA) API: quality scores and link-check results (`https://data.europa.eu/api/mqa/cache/`).
- [ ] Prebuilt SPARQL helpers (counts by country, format, licence) with prefixes preset.
- [ ] "What changed since X" feed for monitoring a topic.
- [ ] Theme and vocabulary lookups (e.g. `ENVI` to its label); high-value-dataset filters.
- [ ] Dump support: one-off converter from the full metadata dump to Parquet or DuckDB (see `metadata-dump.md`); keep it an optional helper, not a core dependency.

## 4. Make it adoptable
- [ ] Docs sites (mkdocs, Documenter.jl, pkgdown) with the same worked examples in all three languages; notebooks as examples. Sites live at https://randsley.github.io/dataeuropa/ (home, getting started, reference); worked examples and notebooks still to do.
- [ ] Releases: PyPI, Julia General registry, r-universe first, CRAN later.
- [x] Full MIT licence text, recognised by GitHub, with a copy in each package folder.
- [ ] CHANGELOG, `CITATION.cff`, Zenodo DOI.
- [x] Replace the placeholder email in `r/DESCRIPTION` before any CRAN submission.
- [ ] Announce: Julia Discourse, rOpenSci, the portal's own community.

## 5. Agent layer
- [ ] Small MCP server on top of the Python client returning clean tables, facets and downloads (existing MCP servers are thin wrappers around raw search).
- [ ] Keep `.claude/skills/data-europa-eu/SKILL.md` and `CLAUDE.md` updated as features land.

## Out of scope for now
- Publisher-side write API of the Registry (needs credentials; few users).
