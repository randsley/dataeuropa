# Roadmap

Goal: make this repo the default way to get from "I need EU open data on X" to a DataFrame, in Python, Julia and R, with identical behaviour in all three.

Suggested order: phase 1, then `load_distribution` and caching from phase 2, then docs and a first release (phase 4), then phases 3 and 5. A first release with solid tests and a one-line "search to DataFrame" workflow is worth more than a larger feature set.

## 1. Make it trustworthy
- [x] CI on GitHub Actions for all three languages: offline tests on every push, live tests on a weekly schedule.
- [x] Recorded fixtures (real API responses saved as JSON) for the offline tests: `fixtures/`.
- [x] Shared conformance suite: the same fixtures must produce the same table in Python, Julia and R (17 cases in `fixtures/cases.json`).
- [ ] API-drift check: compare the live API against the published OpenAPI spec (`https://data.europa.eu/api/hub/search/openapi.yaml`) on a schedule.
- [x] Run Julia `Pkg.test()` on a normal machine (the registry error was a wrong `Test` UUID in `julia/test/Project.toml`; fixed).
- [x] Verify that `bbox` actually filters results. It does (overlap match), but drops datasets without a spatial extent (~47%); now validated client-side and documented.

## 2. Close the "found it, now give me the data" gap
- [ ] `load_distribution()`: download and read straight into a DataFrame (CSV, JSON, XLSX, Parquet).
- [ ] Verify downloads against the API's SHA-1 checksum and `byte_size`.
- [ ] Resumable downloads and an on-disk cache with a time limit (facets, catalogues, dataset records).
- [ ] Skip service entries (WMS, WFS, INSPIRE DOWNLOAD SERVICE) when a file is wanted; geodata loaders (GeoDataFrame, `sf`, GeoDataFrames.jl).

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
