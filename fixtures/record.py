"""Record real data.europa.eu responses as shared test fixtures.

Run from the repo root:  python fixtures/record.py
Then regenerate the expected tables:  python fixtures/make_expected.py

Only `requests` is needed. The recorded files are trimmed so the fixtures stay small; review the
diff before committing, because the portal's data changes over time.
"""
from __future__ import annotations

import json
import pathlib

import requests

SEARCH = "https://data.europa.eu/api/hub/search"
SPARQL = "https://data.europa.eu/sparql"
OUT = pathlib.Path(__file__).parent / "responses"
UA = {"User-Agent": "dataeuropa-fixtures (+https://github.com/randsley/dataeuropa)"}

# A query whose results are multilingual and carry several distribution formats.
SEARCH_PARAMS = {"q": "water quality", "filters": "dataset", "limit": 5, "aggregation": "false",
                 "facets": json.dumps({"country": ["de"], "format": ["CSV"]})}
# A dataset with six formats (CSV, GML, JSON, KML, SHP, WMS); the WMS service has no download URL.
DATASET_ID = "3b26eacb-825d-4bf9-9ef2-9278c4a481ad"
FACET_PARAMS = {"q": "flood", "filters": "dataset", "limit": 0, "aggregation": "true",
                "aggregationAllFields": "false", "aggregationFields": "format"}
# OPTIONAL makes some bindings lack ?periodicity, which exercises missing values.
SPARQL_SELECT = """
SELECT ?d ?title ?periodicity WHERE {
  ?d a <http://www.w3.org/ns/dcat#Dataset> ; <http://purl.org/dc/terms/title> ?title .
  OPTIONAL { ?d <http://purl.org/dc/terms/accrualPeriodicity> ?periodicity }
} LIMIT 12
"""
SPARQL_ASK = "ASK { ?s a <http://www.w3.org/ns/dcat#Dataset> }"


def get(url: str, **params) -> dict:
    r = requests.get(url, params=params, headers=UA, timeout=60)
    r.raise_for_status()
    return r.json()


def sparql(query: str) -> dict:
    r = requests.post(SPARQL, data={"query": query}, timeout=120,
                      headers={**UA, "Accept": "application/sparql-results+json"})
    r.raise_for_status()
    return r.json()


def save(name: str, obj) -> None:
    path = OUT / name
    path.write_text(json.dumps(trim(obj), ensure_ascii=False, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {path.relative_to(OUT.parent.parent)} ({path.stat().st_size:,} bytes)")


KEEP_LANGS = ("en", "de", "fr", "pt")
MAX_TEXT = 200


def trim(x):
    """Shrink a response without changing its shape.

    Multilingual {lang: text} maps keep only KEEP_LANGS (or their first entry if none of those is
    present), long strings are cut to MAX_TEXT characters, and `translation_meta` is dropped.
    """
    if isinstance(x, dict):
        keys = list(x)
        if len(keys) > 4 and all(len(k) == 2 and k.islower() for k in keys):
            kept = {k: x[k] for k in KEEP_LANGS if k in x} or {keys[0]: x[keys[0]]}
            return {k: trim(v) for k, v in kept.items()}
        return {k: trim(v) for k, v in x.items() if k != "translation_meta"}
    if isinstance(x, list):
        return [trim(v) for v in x]
    if isinstance(x, str) and len(x) > MAX_TEXT:
        return x[:MAX_TEXT]
    return x


def main() -> None:
    OUT.mkdir(exist_ok=True)
    save("search.json", get(f"{SEARCH}/search", **SEARCH_PARAMS)["result"])
    save("dataset.json", get(f"{SEARCH}/datasets/{DATASET_ID}")["result"])
    save("facets.json", get(f"{SEARCH}/search", **FACET_PARAMS)["result"])
    save("sparql_select.json", sparql(SPARQL_SELECT))
    save("sparql_ask.json", sparql(SPARQL_ASK))


if __name__ == "__main__":
    main()
