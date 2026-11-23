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


def _bbox_params(bbox: Sequence[float]) -> dict:
    """Check ``(min_lon, min_lat, max_lon, max_lat)`` and return the Search API parameters.

    The API ignores an incomplete box and rejects min > max with an unhelpful 400, so check here.
    """
    try:
        vals = [float(v) for v in bbox]
    except (TypeError, ValueError):
        raise ValueError("bbox must be 4 numbers: (min_lon, min_lat, max_lon, max_lat)") from None
    if len(vals) != 4:
        raise ValueError("bbox must be 4 numbers: (min_lon, min_lat, max_lon, max_lat)")
    min_lon, min_lat, max_lon, max_lat = vals
    if not (-180 <= min_lon <= max_lon <= 180):
        raise ValueError("bbox longitudes must satisfy -180 <= min_lon <= max_lon <= 180")
    if not (-90 <= min_lat <= max_lat <= 90):
        raise ValueError("bbox latitudes must satisfy -90 <= min_lat <= max_lat <= 90")
    return dict(zip(("bboxMinLon", "bboxMinLat", "bboxMaxLon", "bboxMaxLat"), vals))


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
    ``sort`` is e.g. ``"modified+desc"``.

    ``bbox`` is ``(min_lon, min_lat, max_lon, max_lat)`` in WGS84 degrees. A dataset matches when
    its spatial extent overlaps the box, so datasets covering all of Europe or the world match any
    box. Datasets without a spatial extent (about half the portal) never match.
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
    if bbox is not None:
        params.update(_bbox_params(bbox))
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
    return d if raw else {**summarise_dataset(d, lang), "keywords": _keywords(d, lang), "raw": d}


def _keywords(d: dict, lang: str = "en") -> list:
    """Keyword labels in ``lang``, plus those with no language tag."""
    return [k.get("label") for k in d.get("keywords") or [] if k.get("language") in (lang, None)]


def distributions(dataset_id: str, *, lang: str = "en", as_dataframe: bool = True):
    """Distributions (files / services) of a dataset as a table."""
    return _tabulate(_distribution_rows(get_dataset(dataset_id, raw=True), lang), as_dataframe)


def _distribution_rows(d: dict, lang: str = "en") -> list[dict]:
    """One row per distribution of a raw dataset record; ``url`` is the download URL, else the access URL."""
    rows = []
    for x in d.get("distributions") or []:
        acc = x.get("access_url") or []
        dl = x.get("download_url") or []
        cs_algo, cs_value = _checksum(x.get("checksum"))
        rows.append({
            "id": x.get("id"),
            "title": pick_lang(x.get("title"), lang),
            "format": (x.get("format") or {}).get("id"),
            "media_type": x.get("media_type"),
            "byte_size": x.get("byte_size"),
            "checksum": cs_value,
            "checksum_algorithm": cs_algo,
            "license": (x.get("license") or {}).get("id"),
            "modified": x.get("modified"),
            "download_url": dl[0] if dl else None,
            "access_url": acc[0] if acc else None,
            "url": (dl[0] if dl else (acc[0] if acc else None)),
        })
    return rows


# Hash algorithms that downloads can be checked with. The portal also has a few others (e.g. CRC).
_HASHES = ("md5", "sha1", "sha256")
# Hash lengths in hex digits, for checksums that do not name their algorithm.
_HASH_BY_LENGTH = {32: "md5", 40: "sha1", 64: "sha256"}


def _checksum(cs: Any) -> tuple[str | None, str | None]:
    """``(algorithm, value)`` of a distribution's ``checksum`` field, both lowercase, or ``(None, None)``.

    The algorithm is normalised (``"SHA-256"`` and SPDX's ``"...checksumAlgorithm_sha256"`` become
    ``"sha256"``). When it is not given, a hex value of 32, 40 or 64 digits counts as MD5, SHA-1 or
    SHA-256; otherwise the algorithm is None.
    """
    if not isinstance(cs, dict) or not isinstance(cs.get("checksum_value"), str) or not cs["checksum_value"].strip():
        return None, None
    value = cs["checksum_value"].strip().lower()
    algo = cs.get("algorithm")
    if isinstance(algo, str) and algo.strip():
        algo = algo.strip().lower().rsplit("checksumalgorithm_", 1)[-1].replace("-", "").replace("_", "")
    elif all(c in "0123456789abcdef" for c in value):
        algo = _HASH_BY_LENGTH.get(len(value))
    else:
        algo = None
    return algo, value


def _file_hash(path: str | os.PathLike, algorithm: str) -> str:
    """Lowercase hex digest of a file with ``algorithm`` (``"md5"``, ``"sha1"`` or ``"sha256"``)."""
    import hashlib

    h = hashlib.new(algorithm)
    with open(path, "rb") as fh:
        for part in iter(lambda: fh.read(1 << 20), b""):
            h.update(part)
    return h.hexdigest()


def _verify_checksum(path: str | os.PathLike, algorithm: str | None, value: str | None) -> bool:
    """Check a downloaded file against its checksum. Returns True if checked, False if there was
    nothing to check with (no checksum, or an algorithm other than MD5, SHA-1, SHA-256). On a
    mismatch, deletes the file and raises ``ValueError``."""
    if not isinstance(algorithm, str) or algorithm not in _HASHES or not isinstance(value, str) or not value:
        return False
    got = _file_hash(path, algorithm)
    if got != value.lower():
        os.remove(path)
        raise ValueError(f"checksum mismatch: expected {algorithm} {value.lower()}, got {got}; "
                         f"the file was deleted (pass verify=False to keep it)")
    return True


def download(url_or_row: str | dict, dest: str | os.PathLike | None = None, *, chunk: int = 1 << 20,
             verify: bool = True) -> str:
    """Download a distribution to ``dest`` (file or directory). Returns the local path.

    Accepts a URL, or a row/dict from :func:`distributions` (uses its ``url``). Streams to disk.

    If the row has a checksum (``checksum`` and ``checksum_algorithm``; MD5, SHA-1 or SHA-256), the
    file is checked against it. On a mismatch the file is deleted and ``ValueError`` is raised;
    ``verify=False`` skips the check. ``byte_size`` is not checked: on the portal it is often a
    placeholder (0, 1, 1024).
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
    if verify and not isinstance(url_or_row, str):
        _verify_checksum(path, url_or_row.get("checksum_algorithm"), url_or_row.get("checksum"))
    return path


# ---------------------------------------------------------------- load into a table

# Format ids, media types and file extensions that map to a readable file format.
_FILE_FORMATS = {
    "csv": "csv", "text/csv": "csv", "csv/utf8": "csv", "comma separated value (csv)": "csv",
    "json": "json", "application/json": "json",
    "xlsx": "xlsx", "xlsm": "xlsx",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
    "parquet": "parquet", "application/vnd.apache.parquet": "parquet", "application/x-parquet": "parquet",
}
# Media types and extensions of compressed archives, which must be unpacked before reading.
_ARCHIVES = {"application/zip", "application/x-zip-compressed", "application/gzip", "application/x-gzip",
             "application/x-tar", "zip", "gz", "tgz", "tar"}
# Format ids of services (map servers, APIs) rather than files. Ids ending in "_srvc" count too.
_SERVICE_FORMATS = {
    "wms", "wfs", "wcs", "wmts", "ogc:wms", "ogc:wfs", "api", "open-api", "ogc api features",
    "ogcapi-features", "arcgis geoservices rest api", "application/vnd.ogc.wms_xml", "sparql",
}


def _file_format(fmt: str | None = None, media_type: str | None = None, url: str | None = None) -> str | None:
    """``"csv"``, ``"json"``, ``"xlsx"``, ``"parquet"``, ``"service"``, ``"archive"`` or None (unknown).

    A compressed media type or file extension (ZIP, gzip, tar) means ``"archive"``, whatever the
    format id says. Otherwise looks at the format id, then the media type, then the file
    extension, and uses the first one it recognises.
    """
    ext = None
    if isinstance(url, str) and url:
        path = url.split("?", 1)[0].split("#", 1)[0].rstrip("/")
        last = path.rsplit("/", 1)[-1]
        ext = last.rsplit(".", 1)[-1] if "." in last else None
    for cand in (media_type, ext):
        if isinstance(cand, str) and cand.strip().lower() in _ARCHIVES:
            return "archive"
    for cand in (fmt, media_type, ext):
        if not isinstance(cand, str) or not cand.strip():
            continue
        key = cand.strip().lower()
        if key.startswith("file:///"):
            key = key.rsplit("/", 1)[-1]
        if key in _SERVICE_FORMATS or key.endswith("_srvc"):
            return "service"
        if key in _FILE_FORMATS:
            return _FILE_FORMATS[key]
    return None


def _check_payload(path: str | os.PathLike) -> None:
    """Refuse a downloaded file that is an archive or an HTML page rather than data."""
    with open(path, "rb") as fh:
        head = fh.read(512)
    if head.startswith(b"PK\x03\x04") or head.startswith(b"\x1f\x8b"):
        raise ValueError("the download is a compressed archive (ZIP or gzip); use download() and unpack it")
    start = head.lstrip(b"\xef\xbb\xbf \t\r\n").lower()
    if start.startswith(b"<!doctype html") or start.startswith(b"<html"):
        raise ValueError("the download is an HTML page, not a data file (often a landing page)")


def _decode(raw: bytes) -> str:
    """UTF-8 (with or without a byte-order mark), falling back to Latin-1."""
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


def _sniff_delimiter(text: str) -> str:
    """The most frequent of , ; tab | in the header line (comma on a tie or if none occurs)."""
    header = text.split("\n", 1)[0]
    counts = {d: header.count(d) for d in (",", ";", "\t", "|")}
    best = max(counts.values())
    if best == 0 or counts[","] == best:
        return ","
    return next(d for d in (";", "\t", "|") if counts[d] == best)


def _json_records(data: Any) -> list[dict]:
    """An array of objects, or an object holding exactly one array of objects."""
    if isinstance(data, list) and all(isinstance(r, dict) for r in data):
        return data
    if isinstance(data, dict):
        lists = [v for v in data.values() if isinstance(v, list) and v and all(isinstance(r, dict) for r in v)]
        if len(lists) == 1:
            return lists[0]
    raise ValueError("JSON is not a table: expected an array of objects, or an object holding one")


def _read_table(path: str | os.PathLike, fmt: str, sheet: str | int | None = None):
    """Read a local file of format ``fmt`` into a pandas DataFrame."""
    try:
        import pandas as pd
    except ImportError:
        raise ImportError("load_distribution needs pandas: pip install 'dataeuropa[pandas]'") from None
    if fmt == "csv":
        import io
        with open(path, "rb") as fh:
            text = _decode(fh.read())
        return pd.read_csv(io.StringIO(text), sep=_sniff_delimiter(text), keep_default_na=False, na_values=[""])
    if fmt == "json":
        with open(path, "rb") as fh:
            records = _json_records(json.loads(_decode(fh.read())))
        cols: list[str] = []
        for r in records:
            cols.extend(k for k in r if k not in cols)
        return pd.DataFrame([[r.get(c) for c in cols] for r in records], columns=cols)
    if fmt == "xlsx":
        try:
            import openpyxl  # noqa: F401
        except ImportError:
            raise ImportError("reading XLSX needs openpyxl: pip install 'dataeuropa[xlsx]'") from None
        return pd.read_excel(path, sheet_name=0 if sheet is None else sheet, engine="openpyxl")
    if fmt == "parquet":
        try:
            import pyarrow  # noqa: F401
        except ImportError:
            raise ImportError("reading Parquet needs pyarrow: pip install 'dataeuropa[parquet]'") from None
        return pd.read_parquet(path, engine="pyarrow")
    raise ValueError(f"unsupported format {fmt!r}")


def load_distribution(url_or_row: str | dict, *, format: str | None = None, sheet: str | int | None = None):
    """Download a distribution and read it into a pandas DataFrame.

    Accepts a URL, or a row/dict from :func:`distributions`. Reads CSV and JSON (needs pandas),
    XLSX (needs openpyxl) and Parquet (needs pyarrow). The format comes from ``format`` if given
    (``"csv"``, ``"json"``, ``"xlsx"``, ``"parquet"``), else from the row's format id, its media
    type, then the URL's file extension. ``sheet`` picks an XLSX sheet by name or 0-based index
    (default: the first).

    CSV: the delimiter (``,`` ``;`` tab ``|``) is taken from the header line, text is read as
    UTF-8 with a Latin-1 fallback, and only empty cells count as missing. JSON: an array of
    objects, or an object holding exactly one such array; keys become columns.

    Raises ``ValueError`` for services (WMS, WFS, APIs), compressed archives, HTML pages served
    instead of data, formats it cannot tell or read, and files that fail their checksum (see
    :func:`download`).
    """
    import tempfile

    row = {"url": url_or_row} if isinstance(url_or_row, str) else url_or_row
    url = row.get("url")
    if not url:
        raise ValueError("no URL available for this distribution")
    if format is not None:
        fmt = _file_format(format)
        if fmt in (None, "service"):
            raise ValueError(f"format must be one of csv, json, xlsx, parquet (got {format!r})")
    else:
        fmt = _file_format(row.get("format"), row.get("media_type"), url)
    if fmt == "service":
        raise ValueError(f"{url} is a service ({row.get('format')}), not a file; open it with a client for that service")
    if fmt == "archive":
        raise ValueError(f"{url} is a compressed archive; use download() and unpack it")
    if fmt is None:
        raise ValueError(f"cannot tell the file format of {url}; pass format='csv', 'json', 'xlsx' or 'parquet'")
    with tempfile.TemporaryDirectory() as tmp:
        path = download(url_or_row, os.path.join(tmp, f"distribution.{fmt}"))
        if fmt in ("csv", "json"):  # XLSX and Parquet are binary; their readers report bad files themselves
            _check_payload(path)
        return _read_table(path, fmt, sheet)


def facet_values(facet: str, q: str | None = None, *, top: int | None = 50, filters: str = "dataset",
                 **kw) -> Any:
    """List the values (and counts) of a facet, e.g. ``"country"``, ``"format"``, ``"categories"``."""
    fid = _FACET_ALIASES.get(facet, facet)
    res = search(q, filters=filters, limit=0, aggregation=True,
                 extra={"aggregationAllFields": "false", "aggregationFields": fid}, **kw)
    rows = _facet_rows(res, fid, top)
    if rows is None:
        raise KeyError(f"unknown facet {facet!r}")
    return _tabulate(rows, True)


def _facet_rows(res: dict, fid: str, top: int | None = None) -> list[dict] | None:
    """Rows (id, label, count) of facet ``fid`` in a search result, most frequent first; None if absent.

    ``label`` is the item's title, else its label, else its id; a missing ``count`` is 0.
    Ties keep the API's order.
    """
    for f in res.get("facets") or []:
        if f.get("id") == fid:
            rows = [{"id": i.get("id"),
                     "label": pick_lang(i.get("title")) or i.get("label") or i.get("id"),
                     "count": int(i.get("count") or 0)} for i in f.get("items") or []]
            rows.sort(key=lambda x: -x["count"])
            return rows[:top] if top else rows
    return None


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
    res = _sparql_rows(r.json())
    return res if isinstance(res, bool) else _tabulate(res, as_dataframe)


def _sparql_rows(j: dict) -> bool | list[dict]:
    """ASK result as a bool, or SELECT bindings as rows of plain string values (None when unbound)."""
    if "boolean" in j:
        return bool(j["boolean"])
    cols = j["head"]["vars"]
    return [{c: (b[c]["value"] if c in b else None) for c in cols} for b in j["results"]["bindings"]]
