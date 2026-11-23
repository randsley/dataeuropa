"""Check that data.europa.eu still offers what the Python, Julia and R clients rely on.

Run from the repo root:  python tools/check_api.py   (needs requests and PyYAML)

1. Parameters: every query parameter the clients send must still be listed in the published
   OpenAPI spec. Other changes to the spec (version, added or removed parameters on the endpoints
   we use) are reported as warnings against tools/api_baseline.json; accept them with
   --update-baseline.
2. Responses: live calls must still contain every field the clients read, with the expected type.
   The spec does not describe these responses, so this is checked against real data.

Exit status 1 if anything the clients rely on is missing. Runs weekly in GitHub Actions
(.github/workflows/api-check.yml); in Actions, problems also appear as annotations.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys

import requests
import yaml

SEARCH = "https://data.europa.eu/api/hub/search"
REPO = "https://data.europa.eu/api/hub/repo"
SPARQL = "https://data.europa.eu/sparql"
SPEC_URL = f"{SEARCH}/openapi.yaml"
BASELINE = pathlib.Path(__file__).with_name("api_baseline.json")
UA = {"User-Agent": "dataeuropa-api-check (+https://github.com/randsley/dataeuropa)"}
IN_ACTIONS = os.environ.get("GITHUB_ACTIONS") == "true"

# Query parameters the clients send, per endpoint (keep in sync with the three clients).
USED_PARAMS = {
    "/search": ["q", "filters", "facets", "limit", "page", "sort", "minDate", "maxDate", "dateType",
                "bboxMinLon", "bboxMinLat", "bboxMaxLon", "bboxMaxLat", "aggregation",
                "aggregationAllFields", "aggregationFields", "scroll"],
    "/scroll": ["scrollId"],
    "/datasets/{id}": ["id"],
    "/catalogues": [],
}

errors: list[str] = []
warnings: list[str] = []


def error(msg: str) -> None:
    errors.append(msg)
    print(f"::error::{msg}" if IN_ACTIONS else f"ERROR    {msg}")


def warn(msg: str) -> None:
    warnings.append(msg)
    print(f"::warning::{msg}" if IN_ACTIONS else f"WARNING  {msg}")


def ok(msg: str) -> None:
    print(f"ok       {msg}")


def get(url: str, **params):
    r = requests.get(url, params=params, headers=UA, timeout=120)
    r.raise_for_status()
    return r


# ---------------------------------------------------------------- 1. spec parameters

def spec_params(spec: dict) -> dict[str, list[str]]:
    comp = (spec.get("components") or {}).get("parameters") or {}
    out = {}
    for path in USED_PARAMS:
        op = ((spec.get("paths") or {}).get(path) or {}).get("get")
        if op is None:
            out[path] = None
            continue
        names = []
        for p in op.get("parameters") or []:
            if "$ref" in p:
                p = comp.get(p["$ref"].split("/")[-1], {})
            if p.get("name"):
                names.append(p["name"])
        out[path] = sorted(names)
    return out


def check_spec(update_baseline: bool) -> None:
    spec = yaml.safe_load(get(SPEC_URL).text)
    version = (spec.get("info") or {}).get("version")
    params = spec_params(spec)
    for path, used in USED_PARAMS.items():
        if params[path] is None:
            error(f"spec: GET {path} is no longer listed")
            continue
        missing = [p for p in used if p not in params[path]]
        if missing:
            error(f"spec: GET {path} no longer lists parameter(s) the clients send: {', '.join(missing)}")
        else:
            ok(f"spec: GET {path} lists all {len(used)} parameter(s) the clients send")

    current = {"spec_version": version, "params": params}
    if update_baseline:
        BASELINE.write_text(json.dumps(current, indent=1) + "\n", encoding="utf-8")
        print(f"baseline updated: {BASELINE}")
        return
    if not BASELINE.exists():
        warn(f"no baseline at {BASELINE.name}; create one with --update-baseline")
        return
    base = json.loads(BASELINE.read_text(encoding="utf-8"))
    if base.get("spec_version") != version:
        warn(f"spec version changed: {base.get('spec_version')} -> {version}")
    for path, names in params.items():
        old = set(base.get("params", {}).get(path) or [])
        new = set(names or [])
        if added := sorted(new - old):
            warn(f"spec: GET {path} gained parameter(s): {', '.join(added)}")
        if removed := sorted(old - new):
            warn(f"spec: GET {path} lost parameter(s): {', '.join(removed)}")


# ---------------------------------------------------------------- 2. live responses

def is_type(value, kind: str) -> bool:
    return {
        "str": isinstance(value, str),
        "int": isinstance(value, int) and not isinstance(value, bool),
        "num": isinstance(value, (int, float)) and not isinstance(value, bool),
        "bool": isinstance(value, bool),
        "list": isinstance(value, list),
        "dict": isinstance(value, dict),
        "text": isinstance(value, (str, dict, list)),  # plain or {lang: text}
    }[kind]


def lookup(obj, path: str):
    """Values at a dotted path; `[]` steps into every list element. Missing keys yield nothing."""
    values = [obj]
    for part in path.split("."):
        nxt = []
        for v in values:
            if part == "[]":
                nxt.extend(v if isinstance(v, list) else [])
            elif isinstance(v, dict) and part in v:
                nxt.append(v[part])
        values = nxt
    return values


def check_fields(where: str, obj, fields: dict[str, str]) -> None:
    """Each path must occur at least once (so renames are caught), and every occurrence must have
    the expected type; JSON null counts as absent."""
    bad = []
    for path, kind in fields.items():
        values = [v for v in lookup(obj, path) if v is not None]
        if not values:
            bad.append(f"{path} missing")
        elif wrong := [v for v in values if not is_type(v, kind)]:
            bad.append(f"{path} not {kind} (e.g. {json.dumps(wrong[0])[:60]})")
    if bad:
        error(f"{where}: " + "; ".join(bad))
    else:
        ok(f"{where}: {len(fields)} field(s) as expected")


# Fields read by summarise_dataset / distributions / get_dataset in the three clients.
RECORD_FIELDS = {
    "id": "str", "title": "text", "description": "text", "country.id": "str", "catalog.id": "str",
    "publisher.name": "str", "issued": "str", "modified": "str", "is_hvd": "bool",
    "quality_meas.scoring": "num", "landing_page.[].resource": "str",
    "distributions": "list", "distributions.[].id": "str", "distributions.[].title": "text",
    "distributions.[].format.id": "str", "distributions.[].download_url": "list",
    "distributions.[].download_url.[]": "str", "distributions.[].access_url": "list",
    "distributions.[].access_url.[]": "str", "distributions.[].media_type": "str",
    "distributions.[].license.id": "str", "distributions.[].modified": "str",
}


def check_responses() -> None:
    res = get(f"{SEARCH}/search", q="water", filters="dataset", limit=50, aggregation="false").json()["result"]
    check_fields("GET /search", res, {"count": "int", "results": "list"})
    check_fields("GET /search records", res, {f"results.[].{k}": v for k, v in RECORD_FIELDS.items()})

    # A dataset with distributions and keywords, so the single-record checks below are meaningful.
    did = next((r["id"] for r in res.get("results") or [] if r.get("distributions") and r.get("keywords")), None)
    if did is None:
        error("GET /search: none of 50 records has both distributions and keywords; cannot check /datasets/{id}")
    if did:
        d = get(f"{SEARCH}/datasets/{did}").json()["result"]
        check_fields("GET /datasets/{id}", d, {"id": "str", "keywords": "list", "keywords.[].label": "str",
                                                "keywords.[].language": "str", "distributions": "list"})
        ttl = get(f"{REPO}/datasets/{did}.ttl").text
        (ok if "dcat" in ttl.lower() else error)("registry .ttl: " + ("contains DCAT" if "dcat" in ttl.lower()
                                                                      else "no DCAT terms in the Turtle"))
        try:
            json.loads(get(f"{REPO}/datasets/{did}.jsonld").text)
            ok("registry .jsonld: valid JSON")
        except ValueError:
            error("registry .jsonld: not valid JSON")

    agg = get(f"{SEARCH}/search", filters="dataset", limit=0, aggregation="true",
              aggregationAllFields="false", aggregationFields="format").json()["result"]
    check_fields("GET /search facets", agg, {"facets": "list", "facets.[].id": "str", "facets.[].items": "list",
                                            "facets.[].items.[].id": "str", "facets.[].items.[].count": "int"})
    if not any(f.get("id") == "format" for f in agg.get("facets") or []):
        error("GET /search facets: no facet with id 'format' in the aggregation result")

    sc = get(f"{SEARCH}/search", q="water", filters="dataset", limit=5, scroll="true").json()["result"]
    check_fields("GET /search scroll", sc, {"scrollId": "str", "results": "list"})
    if isinstance(sc.get("scrollId"), str):
        nxt = get(f"{SEARCH}/scroll", scrollId=sc["scrollId"]).json()["result"]
        check_fields("GET /scroll", nxt, {"results": "list"})

    cats = get(f"{SEARCH}/catalogues").json()
    if isinstance(cats, list) and cats and all(isinstance(c, str) for c in cats):
        ok(f"GET /catalogues: {len(cats)} catalogue ids")
    else:
        error("GET /catalogues: not a list of id strings")

    hdr = {**UA, "Accept": "application/sparql-results+json"}
    sel = requests.post(SPARQL, data={"query": "SELECT ?s WHERE { ?s a <http://www.w3.org/ns/dcat#Dataset> } LIMIT 3"},
                        headers=hdr, timeout=120)
    sel.raise_for_status()
    check_fields("SPARQL SELECT", sel.json(), {"head.vars": "list", "results.bindings": "list",
                                               "results.bindings.[].s.value": "str"})
    ask = requests.post(SPARQL, data={"query": "ASK { ?s ?p ?o }"}, headers=hdr, timeout=120)
    ask.raise_for_status()
    check_fields("SPARQL ASK", ask.json(), {"boolean": "bool"})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--update-baseline", action="store_true", help="accept the current spec as the baseline")
    args = ap.parse_args()
    for step in (lambda: check_spec(args.update_baseline), check_responses):
        try:
            step()
        except requests.RequestException as e:
            error(f"request failed: {e}")
    print(f"\n{len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
