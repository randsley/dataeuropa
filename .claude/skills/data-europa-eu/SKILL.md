---
name: data-europa-eu
description: Find, inspect and download open datasets from data.europa.eu (the European data portal) via its Search API, Registry RDF and SPARQL endpoint. Use whenever the user wants EU/national open data, dataset metadata, catalogues, file formats or licences from data.europa.eu.
---

# data.europa.eu access

Portal: ~1.9 M dataset records harvested from EU institutions and national/regional portals (DCAT-AP metadata). **The portal holds metadata; the data files live on the publishers' servers.** Always: find dataset -> list distributions -> download from the publisher URL.

## Prefer the packages if installed
Python `dataeuropa`, Julia `DataEuropa`, R `dataeuropa` (same verbs: search_datasets, get_dataset, distributions, download, facet_values, count, catalogues, get_rdf, sparql; R functions are prefixed `de_`). In this repo they live in `python/`, `julia/` and `r/`. If absent, use plain HTTP as below (no package needed).

## Endpoints (no auth, JSON)
- Search: `GET https://data.europa.eu/api/hub/search/search`
- One dataset (flattened, same shape as a search hit): `GET .../search/datasets/{id}`
- Catalogue ids: `GET .../search/catalogues`
- Scroll (bulk): add `scroll=true` to a search, then `GET .../search/scroll?scrollId=...` until `results` is empty
- RDF: `GET https://data.europa.eu/api/hub/repo/datasets/{id}.ttl` or `.jsonld`
- SPARQL: `POST https://data.europa.eu/sparql` form field `query`, header `Accept: application/sparql-results+json`

## Search parameters that matter
`q` free text; `filters=dataset` (also catalogue, dataservice, resource); `limit` 0-1000 (0 = counts/facets only); `page` from 0; `sort=modified+desc`; `minDate`/`maxDate` with `dateType=issued|modified|temporal`; `aggregation=true` for facet counts; `facets` = JSON string, e.g. `{"country":["pt"],"format":["CSV"],"categories":["ENVI"]}`.
- Facet ids: country (lowercase ISO-2), catalog, format (CSV, JSON, XLSX, ZIP, WMS_SRVC ...), license, categories (DCAT-AP themes: AGRI ECON ENVI GOVE HEAL TECH TRAN ...), publisher, keywords, is_hvd (`true`/`false`), source_type, superCatalog, scoring.
- Values inside one facet are OR-ed, different facets are AND-ed. An empty result often just means the combination is empty (e.g. 'flood' + PT + CSV = 0); drop a facet before suspecting a bug.
- To discover valid facet ids: `limit=0&aggregation=true&aggregationAllFields=false&aggregationFields=format`.

## Record shape (hit or /datasets/{id})
`id`, `title`/`description` as `{lang: text}` (pick user's language, fall back to `en`), `country.id`, `catalog.id`, `publisher.name`, `issued`, `modified`, `landing_page[0].resource`, `quality_meas.scoring`, `is_hvd`, and `distributions[]` each with `id`, `title`, `format.id`, `media_type`, `byte_size`, `checksum` (`algorithm`, `checksum_value`; rare), `license.id`, `download_url[]`, `access_url[]`. Prefer `download_url`, fall back to `access_url`.

## Workflow
1. Search narrowly (facets) and count first (`limit=0`); show the user the top hits (id, title, publisher, country, formats, modified).
2. Fetch the chosen dataset, list distributions, state format/size/licence before downloading.
3. Download to a new directory (confirm with the user for large files); verify the `checksum` when given (MD5, SHA-1 or SHA-256; infer from length if `algorithm` is missing). Do not trust `byte_size`: it is often a placeholder (0, 1, 1024).
4. Report licence and portal URL `https://data.europa.eu/data/datasets/{id}` so the user can cite it.

## SPARQL
Use for aggregates and joins over the whole DCAT graph; for text search use the Search API instead (SPARQL text filters took ~30 s). Always add `LIMIT`; expect 10-40 s for GROUP BY over distributions. Prefixes: `dcat: <http://www.w3.org/ns/dcat#>`, `dct: <http://purl.org/dc/terms/>`. Count datasets: `SELECT (COUNT(?s) AS ?n) WHERE { ?s a dcat:Dataset }` (about 2.05 M at last check). Format and licence values come back as authority URIs, so strip to the last path segment.

## Pitfalls
- Many distributions are services (WMS, WFS, INSPIRE DOWNLOAD SERVICE), not files; filter by `format` for tabular data (CSV, XLSX, JSON, PARQUET).
- Some publisher URLs are placeholders (`https://localhost/...`) or dead links; report and move on rather than retrying.
- Licence ids are publisher-supplied and not normalised.
- `limit` max 1000; for more, use scroll. Retry 429/5xx with backoff.
- Do not guess dataset ids; use ids from search results.
- Metadata language varies by publisher; titles may not be English.

## Minimal no-package example (Python stdlib)
```python
import json, urllib.request, urllib.parse
B='https://data.europa.eu/api/hub/search'
q=urllib.parse.urlencode({'q':'water quality','filters':'dataset','limit':5,
  'facets':json.dumps({'country':['pt'],'format':['CSV']})})
res=json.load(urllib.request.urlopen(f'{B}/search?{q}'))['result']
print(res['count']); [print(d['id'], d['title'].get('en') or next(iter(d['title'].values()))) for d in res['results']]
```
