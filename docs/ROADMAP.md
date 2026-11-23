# Roadmap

Goal: make this repo the default way to get from "I need EU open data on X" to a DataFrame, in Python, Julia and R, with identical behaviour in all three.

Suggested order: phase 1, then `load_distribution` and caching from phase 2, then docs and a first release (phase 4), then phases 3 and 5. A first release with solid tests and a one-line "search to DataFrame" workflow is worth more than a larger feature set.

## 1. Make it trustworthy
- [x] CI on GitHub Actions for all three languages: offline tests on every push, live tests on a weekly schedule.
- [ ] Recorded fixtures (real API responses saved as JSON) for the offline tests; today they only cover small helpers.
- [ ] Shared conformance suite: the same fixtures must produce the same table in Python, Julia and R.
- [ ] API-drift check: compare the live API against the published OpenAPI spec (`https://data.europa.eu/api/hub/search/openapi.yaml`) on a schedule.
- [ ] Run Julia `Pkg.test()` on a normal machine (it failed in the author's sandbox with a registry error on the `Test` stdlib).
- [ ] Verify that `bbox` actually filters results.

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
- [ ] Docs sites (mkdocs, Documenter.jl, pkgdown) with the same worked examples in all three languages; notebooks as examples.
- [ ] Releases: PyPI, Julia General registry, r-universe first, CRAN later.
- [ ] CHANGELOG, `CITATION.cff`, Zenodo DOI.
- [ ] Replace the placeholder email in `r/DESCRIPTION` before any CRAN submission.
- [ ] Announce: Julia Discourse, rOpenSci, the portal's own community.

## 5. Agent layer
- [ ] Small MCP server on top of the Python client returning clean tables, facets and downloads (existing MCP servers are thin wrappers around raw search).
- [ ] Keep `.claude/skills/data-europa-eu/SKILL.md` and `CLAUDE.md` updated as features land.

## Out of scope for now
- Publisher-side write API of the Registry (needs credentials; few users).
