"""Client for the data.europa.eu Search API, Registry API and SPARQL endpoint."""
from __future__ import annotations

import json
import os
from typing import Any, Iterator, Sequence

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

SEARCH_URL = "https://data.europa.eu/api/hub/search"
REPO_URL = "https://data.europa.eu/api/hub/repo"
SPARQL_URL = "https://data.europa.eu/sparql"

# Friendly keyword -> facet id used by the Search API.
_FACET_ALIASES = {
    "country": "country",
    "catalog": "catalog",
    "catalogue": "catalog",
    "format": "format",
    "license": "license",
    "licence": "license",
    "category": "categories",
    "categories": "categories",
    "publisher": "publisher",
    "keyword": "keywords",
    "keywords": "keywords",
    "hvd": "is_hvd",
    "source_type": "source_type",
    "super_catalog": "superCatalog",
}

_session: requests.Session | None = None


def _get_session() -> requests.Session:
    global _session
    if _session is None:
        s = requests.Session()
        retry = Retry(total=4, backoff_factor=0.8, status_forcelist=(429, 500, 502, 503, 504),
                      allowed_methods=("GET", "POST"))
        s.mount("https://", HTTPAdapter(max_retries=retry))
        s.headers["User-Agent"] = "dataeuropa-python/0.1 (+https://data.europa.eu)"
        _session = s
    return _session


def _timeout() -> float:
    return float(os.environ.get("DATAEUROPA_TIMEOUT", "60"))


def pick_lang(value: Any, lang: str = "en") -> str | None:
    """Collapse a ``{lang: text}`` mapping to one string (lang, then en, then any)."""
    if value is None:
        return None
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for k in (lang, "en"):
            if value.get(k):
                return value[k]
        for v in value.values():
            if v:
                return v
        return None
    if isinstance(value, list):
        return pick_lang(value[0], lang) if value else None
    return str(value)


def _build_facets(facets: dict | None, **named: Any) -> dict | None:
    out: dict[str, list[str]] = {k: list(v) for k, v in (facets or {}).items()}
    for key, val in named.items():
        if val is None:
            continue
        fid = _FACET_ALIASES[key]
        if isinstance(val, bool):
            vals = ["true" if val else "false"]
        elif isinstance(val, str):
            vals = [val.lower() if fid == "country" else val]
        else:
            vals = [str(v).lower() if fid == "country" else str(v) for v in val]
        out.setdefault(fid, []).extend(vals)
    return out or None


def search(q: str | None = None, *, filters: str | Sequence[str] = "dataset",
           facets: dict | None = None, limit: int = 10, page: int = 0,
           sort: str | Sequence[str] | None = None, country: str | Sequence[str] | None = None,
           catalog: str | Sequence[str] | None = None, format: str | Sequence[str] | None = None,
           license: str | Sequence[str] | None = None, category: str | Sequence[str] | None = None,
           publisher: str | Sequence[str] | None = None, keywords: str | Sequence[str] | None = None,
           hvd: bool | None = None, min_date: str | None = None, max_date: str | None = None,
           date_type: str | None = None, bbox: Sequence[float] | None = None,
           aggregation: bool = False, extra: dict | None = None) -> dict:
    """Raw Search API call. Returns the ``result`` object: ``count``, ``results``, ``facets``...

    ``country`` takes ISO-2 codes (``"pt"``); ``format`` takes ids such as ``"CSV"``;
    ``category`` takes DCAT-AP theme codes (``"ENVI"``). Use :func:`facet_values` to discover ids.
    ``sort`` is e.g. ``"modified+desc"``. ``bbox`` is (minLon, minLat, maxLon, maxLat).
    """
    params: dict[str, Any] = {"limit": limit, "page": page, "aggregation": str(aggregation).lower()}
    if q:
        params["q"] = q
    if filters:
        params["filters"] = filters if isinstance(filters, str) else ",".join(filters)
    fac = _build_facets(facets, country=country, catalog=catalog, format=format, license=license,
                        category=category, publisher=publisher, keywords=keywords, hvd=hvd)
    if fac:
        params["facets"] = json.dumps(fac, separators=(",", ":"))
    if sort:
        params["sort"] = sort if isinstance(sort, str) else ",".join(sort)
    if min_date:
        params["minDate"] = min_date
    if max_date:
        params["maxDate"] = max_date
    if date_type:
        params["dateType"] = date_type
    if bbox:
        params.update(zip(("bboxMinLon", "bboxMinLat", "bboxMaxLon", "bboxMaxLat"), bbox))
    params.update(extra or {})
    r = _get_session().get(f"{SEARCH_URL}/search", params=params, timeout=_timeout())
    _raise(r)
    return r.json()["result"]


def _raise(r: requests.Response) -> None:
    if r.status_code >= 400:
        try:
            msg = r.json().get("message", r.text[:300])
        except Exception:
            msg = r.text[:300]
        raise requests.HTTPError(f"{r.status_code} from {r.url}: {msg}", response=r)


def summarise_dataset(d: dict, lang: str = "en") -> dict:
    """Flatten one dataset record to the fields people usually want."""
    dists = d.get("distributions") or []
    fmts = sorted({(x.get("format") or {}).get("id") for x in dists if (x.get("format") or {}).get("id")})
    cat = d.get("catalog") or {}
    lp = d.get("landing_page") or []
    return {
        "id": d.get("id"),
        "title": pick_lang(d.get("title"), lang),
        "description": pick_lang(d.get("description"), lang),
        "country": (d.get("country") or {}).get("id"),
        "catalog": cat.get("id"),
        "publisher": (d.get("publisher") or {}).get("name"),
        "issued": d.get("issued"),
        "modified": d.get("modified"),
        "formats": fmts,
        "n_distributions": len(dists),
        "is_hvd": d.get("is_hvd"),
        "quality_score": (d.get("quality_meas") or {}).get("scoring"),
        "landing_page": (lp[0].get("resource") if lp and isinstance(lp[0], dict) else None),
        "portal_url": f"https://data.europa.eu/data/datasets/{d.get('id')}",
    }


def search_datasets(q: str | None = None, *, lang: str = "en", as_dataframe: bool = True, **kw):
    """Search datasets and return a table (pandas DataFrame if available, else list of dicts).

    Accepts all keyword arguments of :func:`search`. ``count`` (total hits) is stored in
    ``df.attrs["count"]`` for DataFrames.
    """
    res = search(q, **kw)
    rows = [summarise_dataset(d, lang) for d in res["results"]]
    return _tabulate(rows, as_dataframe, count=res["count"])


def _tabulate(rows: list[dict], as_dataframe: bool, **attrs):
    if as_dataframe:
        try:
            import pandas as pd
        except ImportError:
            return rows
        df = pd.DataFrame(rows)
        df.attrs.update(attrs)
        return df
    return rows


def iter_datasets(q: str | None = None, *, max_results: int | None = None, page_size: int = 500,
                  **kw) -> Iterator[dict]:
    """Yield *raw* dataset records for an arbitrarily large result set using scroll."""
    kw.pop("limit", None)
    kw.pop("page", None)
    extra = dict(kw.pop("extra", None) or {})
    extra["scroll"] = "true"
    res = search(q, limit=min(page_size, 1000), extra=extra, **kw)
    n = 0
    while True:
        for d in res["results"]:
            yield d
            n += 1
            if max_results and n >= max_results:
                return
        sid = res.get("scrollId")
        if not res["results"] or not sid:
            return
        r = _get_session().get(f"{SEARCH_URL}/scroll", params={"scrollId": sid}, timeout=_timeout())
        _raise(r)
        res = r.json()["result"]


def fetch_datasets(q: str | None = None, *, max_results: int = 1000, lang: str = "en",
                   as_dataframe: bool = True, **kw):
    """Collect up to ``max_results`` datasets (via scroll) into a table."""
    rows = [summarise_dataset(d, lang) for d in iter_datasets(q, max_results=max_results, **kw)]
    return _tabulate(rows, as_dataframe)


def get_dataset(dataset_id: str, *, raw: bool = False, lang: str = "en") -> dict:
    """Full metadata record for one dataset (id as shown in search results)."""
    r = _get_session().get(f"{SEARCH_URL}/datasets/{dataset_id}", timeout=_timeout())
    _raise(r)
    d = r.json()["result"]
    return d if raw else {**summarise_dataset(d, lang), "keywords": [k.get("label") for k in d.get("keywords", [])
                                                                         if k.get("language") in (lang, None)],
                          "raw": d}


def distributions(dataset_id: str, *, lang: str = "en", as_dataframe: bool = True):
    """Distributions (files / services) of a dataset as a table."""
    d = get_dataset(dataset_id, raw=True)
    rows = []
    for x in d.get("distributions") or []:
        acc = x.get("access_url") or []
        dl = x.get("download_url") or []
        rows.append({
            "id": x.get("id"),
            "title": pick_lang(x.get("title"), lang),
            "format": (x.get("format") or {}).get("id"),
            "media_type": x.get("media_type"),
            "byte_size": x.get("byte_size"),
            "license": (x.get("license") or {}).get("id"),
            "modified": x.get("modified"),
            "download_url": dl[0] if dl else None,
            "access_url": acc[0] if acc else None,
            "url": (dl[0] if dl else (acc[0] if acc else None)),
        })
    return _tabulate(rows, as_dataframe)


def download(url_or_row: str | dict, dest: str | os.PathLike | None = None, *, chunk: int = 1 << 20) -> str:
    """Download a distribution to ``dest`` (file or directory). Returns the local path.

    Accepts a URL, or a row/dict from :func:`distributions` (uses its ``url``). Streams to disk.
    """
    from urllib.parse import urlparse, unquote

    url = url_or_row if isinstance(url_or_row, str) else url_or_row.get("url")
    if not url:
        raise ValueError("no URL available for this distribution")
    r = _get_session().get(url, stream=True, timeout=_timeout(), allow_redirects=True)
    _raise(r)
    name = None
    cd = r.headers.get("content-disposition", "")
    if "filename=" in cd:
        name = cd.split("filename=")[-1].strip("\"' ;")
    name = name or unquote(os.path.basename(urlparse(r.url).path)) or "download"
    if dest is None:
        path = name
    elif os.path.isdir(dest):
        path = os.path.join(dest, name)
    else:
        path = str(dest)
    with open(path, "wb") as fh:
        for part in r.iter_content(chunk):
            fh.write(part)
    return path


def facet_values(facet: str, q: str | None = None, *, top: int | None = 50, filters: str = "dataset",
                 **kw) -> Any:
    """List the values (and counts) of a facet, e.g. ``"country"``, ``"format"``, ``"categories"``."""
    fid = _FACET_ALIASES.get(facet, facet)
    res = search(q, filters=filters, limit=0, aggregation=True,
                 extra={"aggregationAllFields": "false", "aggregationFields": fid}, **kw)
    for f in res.get("facets", []):
        if f["id"] == fid:
            rows = [{"id": i.get("id"), "label": pick_lang(i.get("title")) or i.get("label"),
                     "count": i.get("count")} for i in f["items"]]
            rows.sort(key=lambda x: -(x["count"] or 0))
            return _tabulate(rows[:top] if top else rows, True)
    raise KeyError(f"unknown facet {facet!r}")


def count(q: str | None = None, **kw) -> int:
    """Number of hits for a query (no records transferred)."""
    return int(search(q, limit=0, **kw)["count"])


def catalogues() -> list[str]:
    """Ids of all harvested catalogues."""
    r = _get_session().get(f"{SEARCH_URL}/catalogues", timeout=_timeout())
    _raise(r)
    return r.json()


def get_rdf(dataset_id: str, fmt: str = "ttl") -> str:
    """Dataset metadata as RDF text. ``fmt``: ``ttl`` (Turtle) or ``jsonld``."""
    if fmt not in ("ttl", "jsonld"):
        raise ValueError("fmt must be 'ttl' or 'jsonld'")
    r = _get_session().get(f"{REPO_URL}/datasets/{dataset_id}.{fmt}", timeout=_timeout())
    _raise(r)
    return r.text


def sparql(query: str, *, as_dataframe: bool = True):
    """Run a SPARQL SELECT/ASK query against data.europa.eu. Returns a table of plain values."""
    r = _get_session().post(SPARQL_URL, data={"query": query},
                            headers={"Accept": "application/sparql-results+json"}, timeout=_timeout())
    _raise(r)
    j = r.json()
    if "boolean" in j:
        return j["boolean"]
    cols = j["head"]["vars"]
    rows = [{c: (b[c]["value"] if c in b else None) for c in cols} for b in j["results"]["bindings"]]
    return _tabulate(rows, as_dataframe)
