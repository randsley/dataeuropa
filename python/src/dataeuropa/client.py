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


# ---------------------------------------------------------------- response cache

# Set by cache_on() / cache_off(); None means "use the environment variable".
_cache_settings: dict[str, Any] = {"on": None, "dir": None, "ttl": None}
_CACHE_TTL_DEFAULT = 86400  # one day, in seconds


def _default_cache_dir() -> str:
    """The operating system's cache folder for dataeuropa."""
    import sys

    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~/AppData/Local")
        return os.path.join(base, "dataeuropa", "cache")
    if sys.platform == "darwin":
        return os.path.expanduser("~/Library/Caches/dataeuropa")
    return os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "dataeuropa")


def _cache_enabled() -> bool:
    if _cache_settings["on"] is not None:
        return _cache_settings["on"]
    return os.environ.get("DATAEUROPA_CACHE", "").strip().lower() in ("1", "true", "yes")


def _cache_dir() -> str:
    return _cache_settings["dir"] or os.environ.get("DATAEUROPA_CACHE_DIR") or _default_cache_dir()


def _cache_ttl() -> float:
    if _cache_settings["ttl"] is not None:
        return float(_cache_settings["ttl"])
    return float(os.environ.get("DATAEUROPA_CACHE_TTL") or _CACHE_TTL_DEFAULT)


def cache_on(dir: str | os.PathLike | None = None, ttl: float | None = None) -> str:
    """Turn on the on-disk response cache for this session. Returns the cache folder.

    Cached: dataset records (:func:`get_dataset`, :func:`distributions`), the catalogue list
    (:func:`catalogues`), and searches with ``limit=0`` (:func:`facet_values`, :func:`count`).
    Other searches, SPARQL and file downloads are never cached.

    ``dir`` defaults to ``DATAEUROPA_CACHE_DIR``, else the operating system's cache folder.
    ``ttl`` is how long a response stays valid, in seconds; it defaults to
    ``DATAEUROPA_CACHE_TTL``, else one day. The cache is off unless this is called or
    ``DATAEUROPA_CACHE=1`` is set.
    """
    _cache_settings.update(on=True, dir=str(dir) if dir is not None else None, ttl=ttl)
    path = _cache_dir()
    os.makedirs(path, exist_ok=True)
    return path


def cache_off() -> None:
    """Turn off the response cache for this session (cached files stay; see :func:`clear_cache`)."""
    _cache_settings["on"] = False


def clear_cache() -> int:
    """Delete all cached responses. Returns how many were deleted."""
    import re

    path = _cache_dir()
    if not os.path.isdir(path):
        return 0
    n = 0
    for name in os.listdir(path):
        if re.fullmatch(r"[0-9a-f]{64}\.json", name):
            os.remove(os.path.join(path, name))
            n += 1
    return n


def _cache_key(url: str, params: dict | None = None) -> str:
    """File name of a cached response: SHA-256 of the URL and its sorted query parameters."""
    import hashlib

    query = "&".join(f"{k}={params[k]}" for k in sorted(params)) if params else ""
    return hashlib.sha256(f"{url}?{query}".encode("utf-8")).hexdigest() + ".json"


def _get_json(url: str, params: dict | None = None, *, cacheable: bool = False) -> Any:
    """GET a JSON response, from the cache when it is on, ``cacheable`` and fresh."""
    import time

    path = os.path.join(_cache_dir(), _cache_key(url, params)) if cacheable and _cache_enabled() else None
    ttl = _cache_ttl()  # ttl 0: never fresh, even when the file time is a little ahead of the clock
    if path and ttl > 0 and os.path.isfile(path) and time.time() - os.path.getmtime(path) < ttl:
        with open(path, "rb") as fh:
            return json.loads(fh.read())
    r = _get_session().get(url, params=params, timeout=_timeout())
    _raise(r)
    data = r.json()
    if path:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f"{path}.{os.getpid()}.tmp"   # write, then rename, so readers never see half a file
        with open(tmp, "wb") as fh:
            fh.write(r.content)
        os.replace(tmp, path)
    return data


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

    With ``limit=0`` the result can come from the response cache (see :func:`cache_on`).
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
    # limit=0 (facet counts, hit counts) carries no records, so it may come from the cache.
    return _get_json(f"{SEARCH_URL}/search", params, cacheable=limit == 0)["result"]


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
    d = _get_json(f"{SEARCH_URL}/datasets/{dataset_id}", cacheable=True)["result"]
    return d if raw else {**summarise_dataset(d, lang), "keywords": _keywords(d, lang), "raw": d}


def _keywords(d: dict, lang: str = "en") -> list:
    """Keyword labels in ``lang``, plus those with no language tag."""
    return [k.get("label") for k in d.get("keywords") or [] if k.get("language") in (lang, None)]


def distributions(dataset_id: str, *, lang: str = "en", files_only: bool = False, as_dataframe: bool = True):
    """Distributions (files, services, pages) of a dataset as a table, one row each.

    The ``kind`` column says what each one is: ``"file"``, ``"service"`` (WMS, WFS, APIs, feeds),
    ``"page"`` (a web page), ``"none"`` (no usable URL, e.g. a localhost placeholder) or
    ``"unknown"``. ``files_only=True`` keeps only files.
    """
    rows = _distribution_rows(get_dataset(dataset_id, raw=True), lang)
    if files_only:
        rows = [r for r in rows if r["kind"] == "file"]
    return _tabulate(rows, as_dataframe)


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
            "kind": _distribution_kind((x.get("format") or {}).get("id"), x.get("media_type"),
                                       dl[0] if dl else (acc[0] if acc else None), dl[0] if dl else None),
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


def _range_validator(etag: str | None, last_modified: str | None) -> str | None:
    """The value to send as ``If-Range`` when resuming: a strong ETag, else Last-Modified, else None.
    Weak ETags (``W/"..."``) are not allowed in ``If-Range``."""
    if isinstance(etag, str) and etag.strip() and not etag.strip().startswith("W/"):
        return etag.strip()
    if isinstance(last_modified, str) and last_modified.strip():
        return last_modified.strip()
    return None


def _resume_action(status: int, content_range: str | None, offset: int) -> str:
    """What to do with the reply to a request for bytes ``offset``- of a partial download:
    ``"append"`` (206 from ``offset``), ``"replace"`` (200: the whole file, because the server
    ignores ranges or the file changed), ``"restart"`` (416, or a 206 for other bytes: start again
    without a range) or ``"error"``."""
    import re

    if status == 206:
        m = re.match(r"\s*bytes\s+(\d+)-", content_range or "", re.IGNORECASE)
        return "append" if m and int(m.group(1)) == offset else "restart"
    if status == 200:
        return "replace"
    if status == 416:
        return "restart"
    return "error"


class _TooLarge(ValueError):
    """A download went over its size limit; the partial file was deleted."""


def _fetch(url: str, part: str, *, resume: bool, chunk: int, max_bytes: int | None = None) -> requests.Response:
    """Stream ``url`` into the partial file ``part``, continuing an earlier partial download when
    possible. Returns the (closed) response, for its headers and final URL. Over ``max_bytes``
    (announced or received), deletes the partial file and raises ``_TooLarge``."""
    meta = part + ".json"
    offset = 0
    headers = {"Accept-Encoding": "identity"}  # byte offsets must refer to the file itself
    if resume and os.path.isfile(part) and os.path.isfile(meta):
        try:
            with open(meta, encoding="utf-8") as fh:
                m = json.load(fh)
        except (OSError, ValueError):
            m = {}
        if m.get("url") == url and m.get("validator") and os.path.getsize(part) > 0:
            offset = os.path.getsize(part)
            headers.update({"Range": f"bytes={offset}-", "If-Range": m["validator"]})
    if offset == 0:
        for f in (part, meta):
            if os.path.exists(f):
                os.remove(f)
    r = _get_session().get(url, stream=True, timeout=_timeout(), allow_redirects=True, headers=headers)
    action = _resume_action(r.status_code, r.headers.get("content-range"), offset) if offset else "replace"
    if action == "restart":
        r.close()
        for f in (part, meta):
            if os.path.exists(f):
                os.remove(f)
        return _fetch(url, part, resume=False, chunk=chunk, max_bytes=max_bytes)
    _raise(r)
    start = offset if action == "append" else 0

    def too_large():
        r.close()
        for f in (part, meta):
            if os.path.exists(f):
                os.remove(f)
        return _TooLarge(f"{url} is larger than the limit of {max_bytes:,} bytes; the download was stopped")

    announced = r.headers.get("content-length", "")
    if max_bytes is not None and announced.isdigit() and start + int(announced) > max_bytes:
        raise too_large()
    if action == "replace":
        validator = _range_validator(r.headers.get("etag"), r.headers.get("last-modified"))
        if validator:
            with open(meta, "w", encoding="utf-8") as fh:
                json.dump({"url": url, "validator": validator}, fh)
        elif os.path.exists(meta):
            os.remove(meta)
    size = start
    with open(part, "ab" if action == "append" else "wb") as fh:
        for piece in r.iter_content(chunk):
            size += len(piece)
            if max_bytes is not None and size > max_bytes:
                fh.close()
                raise too_large()
            fh.write(piece)
    r.close()
    if os.path.exists(meta):
        os.remove(meta)
    return r


def download(url_or_row: str | dict, dest: str | os.PathLike | None = None, *, chunk: int = 1 << 20,
             verify: bool = True, resume: bool = True, max_bytes: int | None = None) -> str:
    """Download a distribution to ``dest`` (file or directory). Returns the local path.

    Accepts a URL, or a row/dict from :func:`distributions` (uses its ``url``). Streams to disk.

    If the row has a checksum (``checksum`` and ``checksum_algorithm``; MD5, SHA-1 or SHA-256), the
    file is checked against it. On a mismatch the file is deleted and ``ValueError`` is raised;
    ``verify=False`` skips the check. ``byte_size`` is not checked: on the portal it is often a
    placeholder (0, 1, 1024).

    The file is written as ``<file>.part`` and renamed when complete. If a download is interrupted,
    calling ``download`` again for the same URL and destination continues where it stopped, when
    the server supports ranges and identifies the file (ETag or Last-Modified); a file that changed
    meanwhile is downloaded again from the start. ``resume=False`` always starts from the start.

    ``max_bytes`` stops a download that is (or is announced as) larger, deletes the partial file
    and raises ``ValueError``. Default: no limit.
    """
    from urllib.parse import urlparse, unquote

    url = url_or_row if isinstance(url_or_row, str) else url_or_row.get("url")
    if not url:
        raise ValueError("no URL available for this distribution")
    folder = None if dest is not None and not os.path.isdir(dest) else (str(dest) if dest is not None else "")
    guess = unquote(os.path.basename(urlparse(url).path)) or "download"
    part = (os.path.join(folder, guess) if folder is not None else str(dest)) + ".part"
    r = _fetch(url, part, resume=resume, chunk=chunk, max_bytes=max_bytes)
    if folder is None:
        path = str(dest)
    else:
        name = None
        cd = r.headers.get("content-disposition", "")
        if "filename=" in cd:
            name = cd.split("filename=")[-1].strip("\"' ;")
        name = name or unquote(os.path.basename(urlparse(r.url).path)) or "download"
        path = os.path.join(folder, name)
    os.replace(part, path)
    if verify and not isinstance(url_or_row, str):
        _verify_checksum(path, url_or_row.get("checksum_algorithm"), url_or_row.get("checksum"))
    return path


# ---------------------------------------------------------------- load into a table

# Format ids, media types and file extensions that map to a readable file format. Keys are
# matched after _format_key(): lowercase, look-alike letters folded, leading dot removed.
_FILE_FORMATS = {
    "csv": "csv", "text/csv": "csv", "csv/utf8": "csv", "comma separated value (csv)": "csv",
    "tsv": "csv", "text/tab-separated-values": "csv",  # the CSV reader detects the tab delimiter
    "json": "json", "application/json": "json",
    "xlsx": "xlsx", "xlsm": "xlsx", "excel (.xlsx)": "xlsx",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
    "vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
    "parquet": "parquet", "application/vnd.apache.parquet": "parquet", "application/x-parquet": "parquet",
}
# Media types and extensions of compressed archives, which must be unpacked before reading.
_ARCHIVES = {"application/zip", "application/x-zip-compressed", "application/gzip", "application/x-gzip",
             "application/x-tar", "zip", "gz", "tgz", "tar"}
# Format ids of services (map servers, APIs) rather than files. Ids ending in "_srvc" count too.
# Atom and RSS feeds count as services: in INSPIRE they list files rather than being one.
_SERVICE_FORMATS = {
    "wms", "wfs", "wcs", "wmts", "ogc:wms", "ogc:wfs", "ogc:wcs", "ogc:wmts", "ogc:ows-c", "api", "open-api",
    "ogc api features", "ogcapi-features", "ogcfeat", "arcgis geoservices rest api", "rest", "esri rest",
    "application/vnd.ogc.wms_xml", "sparql", "sparqlq", "inspire download service", "atom", "rss",
    "application/atom+xml", "application/rss+xml",
}
# Format ids and media types of web pages (landing pages, links, viewers) rather than files.
_PAGE_FORMATS = {
    "html", "text/html", "application/xhtml+xml", "web page", "html_simpl", "www:link",
    "www:link-1.0-http--link", "www:link-1.0-http--metadata-url", "url", "view", "doi", "map_prvw",
}
# Look-alike letters some publishers type in format ids (Cyrillic а е о р с х, both cases).
_LOOKALIKES = str.maketrans("\u0430\u0435\u043e\u0440\u0441\u0445\u0410\u0415\u041e\u0420\u0421\u0425",
                            "aeopcxAEOPCX")


def _format_key(value: str) -> str:
    """A format id, media type or extension as matched against the tables above."""
    key = value.strip().translate(_LOOKALIKES).lower()
    if key.startswith("file:///"):
        key = key.rsplit("/", 1)[-1]
    return key.lstrip(".")


def _url_extension(url: str | None) -> str | None:
    """The file extension of a URL's last path part, without query or fragment; None if none."""
    if not isinstance(url, str) or not url:
        return None
    path = url.split("?", 1)[0].split("#", 1)[0].rstrip("/")
    last = path.rsplit("/", 1)[-1]
    return last.rsplit(".", 1)[-1] if "." in last else None


def _file_format(fmt: str | None = None, media_type: str | None = None, url: str | None = None) -> str | None:
    """``"csv"``, ``"json"``, ``"xlsx"``, ``"parquet"``, ``"service"``, ``"archive"``, ``"page"`` or
    None (unknown).

    A compressed media type or file extension (ZIP, gzip, tar) means ``"archive"``, whatever the
    format id says. Otherwise looks at the format id, then the media type, then the file
    extension, and uses the first one it recognises as a service or a readable file. ``"page"``
    (a web page) only when one of them says so and none names a service or a file.
    """
    ext = _url_extension(url)
    for cand in (media_type, ext):
        if isinstance(cand, str) and _format_key(cand) in _ARCHIVES:
            return "archive"
    keys = [_format_key(c) for c in (fmt, media_type, ext) if isinstance(c, str) and c.strip()]
    for key in keys:
        if key in _SERVICE_FORMATS or key.endswith("_srvc"):
            return "service"
        if key in _FILE_FORMATS:
            return _FILE_FORMATS[key]
    return "page" if any(k in _PAGE_FORMATS for k in keys) else None


# Format ids that say nothing about the content ("onLine" is ISO 19115 for "a link").
_NO_FORMAT = {"online", "other", "inconnu", "unknown", "n/a"}
# Hosts that only appear in placeholder URLs.
_PLACEHOLDER_HOSTS = {"localhost", "127.0.0.1", "0.0.0.0", "::1", ""}


def _distribution_kind(fmt: str | None = None, media_type: str | None = None, url: str | None = None,
                       download_url: str | None = None) -> str:
    """What a distribution is: ``"file"``, ``"service"``, ``"page"``, ``"none"`` (no usable URL) or
    ``"unknown"``.

    ``"none"``: no URL, a scheme other than http(s) or ftp, or a placeholder host (localhost).
    ``"service"``: an OGC query in the URL (``service=WMS``, ``request=GetCapabilities``), or a
    service format. ``"page"``: a web-page format, or no format and an ``.html`` URL. ``"file"``:
    any other format or media type, or a download URL. Otherwise ``"unknown"``. Format ids that
    say nothing (``onLine``, ``OTHER``) count as no format.
    """
    import re
    from urllib.parse import urlparse

    if not isinstance(url, str) or not url.strip():
        return "none"
    parts = urlparse(url.strip())
    if parts.scheme.lower() not in ("http", "https", "ftp") or (parts.hostname or "").lower() in _PLACEHOLDER_HOSTS:
        return "none"
    if re.search(r"(^|&)(service=(wms|wfs|wcs|wmts|csw|wps|sos)|request=getcapabilities)(&|$)",
                 parts.query, re.IGNORECASE):
        return "service"
    f = _file_format(fmt, media_type, url)
    if f in ("service", "page"):
        return f
    if f is not None or any(isinstance(v, str) and v.strip() and _format_key(v) not in _NO_FORMAT
                            for v in (fmt, media_type)):
        return "file"
    if (_url_extension(url) or "").lower() in ("html", "htm"):
        return "page"
    return "file" if isinstance(download_url, str) and download_url.strip() else "unknown"


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
        if fmt in (None, "service", "archive", "page"):
            raise ValueError(f"format must be one of csv, json, xlsx, parquet (got {format!r})")
    else:
        fmt = _file_format(row.get("format"), row.get("media_type"), url)
    if fmt == "service":
        raise ValueError(f"{url} is a service ({row.get('format')}), not a file; open it with a client for that service")
    if fmt == "archive":
        raise ValueError(f"{url} is a compressed archive; use download() and unpack it")
    if fmt == "page":
        raise ValueError(f"{url} is a web page, not a file")
    if fmt is None:
        raise ValueError(f"cannot tell the file format of {url}; pass format='csv', 'json', 'xlsx' or 'parquet'")
    with tempfile.TemporaryDirectory() as tmp:
        path = download(url_or_row, os.path.join(tmp, f"distribution.{fmt}"))
        if fmt in ("csv", "json"):  # XLSX and Parquet are binary; their readers report bad files themselves
            _check_payload(path)
        return _read_table(path, fmt, sheet)


# ---------------------------------------------------------------- geodata

# Format ids, media types and extensions of vector geodata files, after _format_key(). Values are
# the file extension the download is saved under (GDAL needs it for some formats); "zip" for
# formats published as ZIP archives (shapefiles, MapInfo, file geodatabases).
_GEO_FORMATS = {
    "geojson": "geojson", "application/geo+json": "geojson", "geo+json": "geojson",
    "application/vnd.geo+json": "geojson",
    "kml": "kml", "application/vnd.google-earth.kml+xml": "kml", "vnd.google-earth.kml+xml": "kml",
    "kmz": "kmz", "application/vnd.google-earth.kmz": "kmz", "vnd.google-earth.kmz": "kmz",
    "gml": "gml", "application/gml+xml": "gml", "gml+xml": "gml", "geographic markup language (gml)": "gml",
    "xplangml": "gml", "kuntagml": "gml",
    "gpkg": "gpkg", "geopackage": "gpkg", "geopackage - gpkg": "gpkg", "application/geopackage+sqlite3": "gpkg",
    "geopackage+sqlite3": "gpkg",
    "gpx": "gpx", "application/gpx+xml": "gpx", "gpx+xml": "gpx",
    "fgb": "fgb", "flatgeobuf": "fgb",
    "shp": "zip", "shape": "zip", "shapefile": "zip", "shapefiles": "zip", "shapefile (zip)": "zip",
    "shapefile zip": "zip", "shp / zip": "zip", "esri shape": "zip", "esri shapefile": "zip",
    "esri shapefile (shp)": "zip", "www:download:esri shapefile": "zip",
    "tab": "zip", "mapinfo tab": "zip", "gdb": "zip", "esri file geodatabase": "zip", "file geodatabase": "zip",
}
# Extensions of the files GDAL is asked to open inside an archive; a ".gdb" folder counts too.
_GEO_MEMBER_EXTS = ("shp", "gpkg", "geojson", "kml", "gml", "gpx", "tab", "fgb")
_NESTED_ARCHIVE_EXTS = ("zip", "kmz", "gz", "tgz", "tar", "7z", "rar")


def _geo_format(fmt: str | None = None, media_type: str | None = None, url: str | None = None) -> str | None:
    """The extension to save a geodata download under (``"geojson"``, ``"kml"``, ``"kmz"``,
    ``"gml"``, ``"gpkg"``, ``"gpx"``, ``"fgb"``, or ``"zip"`` for shapefiles, MapInfo and file
    geodatabases), from the format id, then the media type, then the URL's extension. None if
    none of them names a geodata format."""
    for cand in (fmt, media_type, _url_extension(url)):
        if isinstance(cand, str) and cand.strip():
            key = _format_key(cand)
            if key in _GEO_FORMATS:
                return _GEO_FORMATS[key]
    return None


def _geo_member(names: list[str], layer: str | int | None = None) -> tuple[str, str | int | None]:
    """Choose the file to read inside an archive, from its member ``names``.

    Candidates: files ending in .shp, .gpkg, .geojson, .kml, .gml, .gpx, .tab or .fgb, and .gdb
    folders; macOS metadata (``__MACOSX/``, ``._*``) is ignored. One candidate: that one. Several:
    the one whose name (without extension) or path equals ``layer``, ignoring case; ``layer`` is
    then used up and the second value is None. Otherwise raises ``ValueError`` listing them.
    Returns ``(member, layer left for reading inside it)``.
    """
    files = [n.replace("\\", "/") for n in names if not n.endswith("/") and not n.endswith("\\")]
    files = [n for n in files if not n.startswith("__MACOSX/") and not n.rsplit("/", 1)[-1].startswith("._")]
    cands: list[str] = []
    for n in files:
        low = n.lower()
        if ".gdb/" in low:
            folder = n[:low.index(".gdb/") + 4]
            if folder not in cands:
                cands.append(folder)
        elif "." in low.rsplit("/", 1)[-1] and low.rsplit(".", 1)[-1] in _GEO_MEMBER_EXTS:
            cands.append(n)
    cands.sort()
    if not cands:
        nested = sorted(n for n in files if "." in n.rsplit("/", 1)[-1] and n.rsplit(".", 1)[-1].lower() in _NESTED_ARCHIVE_EXTS)
        if nested:
            raise ValueError(f"the archive holds other archives ({', '.join(nested)}); download() it and unpack them")
        raise ValueError("the archive holds no geodata file (looked for .shp, .gpkg, .geojson, .kml, .gml, .gpx, "
                         ".tab, .fgb files and .gdb folders)")
    if len(cands) == 1:
        return cands[0], layer
    if isinstance(layer, str):
        want = layer.lower()
        hits = [c for c in cands if c.lower() == want or c.rsplit("/", 1)[-1].rsplit(".", 1)[0].lower() == want]
        if len(hits) == 1:
            return hits[0], None
    raise ValueError(f"the archive holds {len(cands)} geodata files ({', '.join(cands)}); pick one with layer=")


# Format ids of the feature services load_geodata reads, after _format_key().
_WFS_FORMATS = {"wfs", "ogc:wfs", "wfs_srvc"}
_OAPIF_FORMATS = {"ogcfeat", "ogc api features", "ogcapi-features"}


def _service_source(fmt: str | None = None, url: str | None = None) -> str | None:
    """The GDAL data source for a feature service: ``"WFS:<url>"`` or ``"OAPIF:<url>"``, or None
    when the distribution is not one (or is another service, such as WMS).

    A ``service=`` parameter in the URL decides (``service=WFS``: WFS, anything else: None),
    because format ids are often wrong. Otherwise an OGC API Features format id, or a URL ending
    in ``/collections/{id}`` or ``/collections/{id}/items``, means OGC API Features (the URL is
    cut to the collection, without query); a WFS format id means WFS. Only http(s) URLs.
    """
    import re
    from urllib.parse import urlparse

    if not isinstance(url, str) or not url.strip():
        return None
    u = url.strip()
    parts = urlparse(u)
    if parts.scheme.lower() not in ("http", "https") or not parts.netloc:
        return None
    m = re.search(r"(?:^|&)service=([^&]*)", parts.query, re.IGNORECASE)
    if m:
        return f"WFS:{u}" if m.group(1).lower() == "wfs" else None
    key = _format_key(fmt) if isinstance(fmt, str) and fmt.strip() else ""
    path = parts.path.rstrip("/")
    collection = re.search(r"/collections/[^/]+(/items)?$", path)
    if key in _OAPIF_FORMATS or collection:
        if collection and collection.group(1):
            path = path[: -len("/items")]
        return f"OAPIF:{parts.scheme}://{parts.netloc}{path}"
    return f"WFS:{u}" if key in _WFS_FORMATS else None


def _pick_layer(layers: list[str], layer: str | int | None = None) -> str:
    """The layer to read: ``layer`` by name (exact, else ignoring case) or 0-based position;
    by default the first, with a warning if there are more."""
    import warnings

    if not layers:
        raise ValueError("the file holds no layers")
    if layer is None:
        if len(layers) > 1:
            warnings.warn(f"the file has {len(layers)} layers ({', '.join(layers)}); reading {layers[0]!r}, "
                          f"pick another with layer=", stacklevel=3)
        return layers[0]
    if isinstance(layer, int) and not isinstance(layer, bool):
        if 0 <= layer < len(layers):
            return layers[layer]
        raise ValueError(f"layer {layer} is out of range: the file has {len(layers)} layers ({', '.join(layers)})")
    if layer in layers:
        return layer
    hits = [n for n in layers if n.lower() == str(layer).lower()]
    if len(hits) == 1:
        return hits[0]
    raise ValueError(f"no layer {layer!r}; the file has {', '.join(layers)}")


def _read_geodata(path: str | os.PathLike, layer: str | int | None = None, crs: Any = None):
    """Read a local geodata file (or a ZIP holding one) into a GeoDataFrame."""
    import warnings
    import zipfile

    try:
        import geopandas
        import pyogrio
    except ImportError:
        raise ImportError("load_geodata needs geopandas and pyogrio: pip install 'dataeuropa[geo]'") from None
    with open(path, "rb") as fh:
        head = fh.read(512)
    start = head.lstrip(b"\xef\xbb\xbf \t\r\n").lower()
    if start.startswith(b"<!doctype html") or start.startswith(b"<html"):
        raise ValueError("the download is an HTML page, not a data file (often a landing page)")
    src = os.path.abspath(path).replace("\\", "/")
    if head.startswith(b"PK\x03\x04"):
        with zipfile.ZipFile(path) as z:
            member, layer = _geo_member(z.namelist(), layer)
        src = f"/vsizip/{src}/{member}"
    elif head.startswith(b"\x1f\x8b"):
        src = f"/vsigzip/{src}"
    return _read_source(src, layer, crs)


def _read_source(src: str, layer: str | int | None = None, crs: Any = None, max_features: int | None = None,
                 what: str = "the file"):
    """Read a GDAL data source (a local path, /vsizip/ path, or WFS:/OAPIF: service) into a
    GeoDataFrame. ``max_features``: read at most that many, with a warning if there are more."""
    import warnings

    import geopandas
    import pyogrio

    try:
        layers = [str(entry[0]) for entry in pyogrio.list_layers(src)]
    except Exception as e:  # pyogrio raises its own DataSourceError
        raise ValueError(f"cannot read {what} as geodata: {e}") from None
    name = _pick_layer(layers, layer)
    extra = {} if max_features is None else {"max_features": max_features + 1}
    try:
        with warnings.catch_warnings():
            warnings.filterwarnings("ignore", message=".*has GPKG application_id.*")
            gdf = geopandas.read_file(src, layer=name, engine="pyogrio", **extra)
    except Exception as e:
        if what == "the file":
            raise
        raise ValueError(f"cannot read {what}: {e}") from None
    if max_features is not None and len(gdf) > max_features:
        warnings.warn(f"{what} has more than {max_features:,} features; read the first {max_features:,} "
                      f"(pass max_features=None for all)", stacklevel=3)
        gdf = gdf.iloc[:max_features]
    if not isinstance(gdf, geopandas.GeoDataFrame) or getattr(gdf, "_geometry_column_name", None) not in gdf.columns:
        raise ValueError(f"{what} has no geometries (a plain table?); use load_distribution()")
    if gdf.crs is None:
        if crs is not None:
            raise ValueError("the data has no coordinate reference system (no .prj file?), so it cannot be "
                             "reprojected; read it without crs= and set one with set_crs()")
        warnings.warn("the data has no coordinate reference system (no .prj file?); coordinates are as stored",
                      stacklevel=2)
    elif crs is not None:
        gdf = gdf.to_crs(crs)
    return gdf


# 2D geometry type names, as reported by GEOS, sf (upper case) and GDAL.
_GEOMETRY_TYPES = {t.upper(): t for t in ("Point", "LineString", "Polygon", "MultiPoint", "MultiLineString",
                                          "MultiPolygon", "GeometryCollection")}


def _geo_summary(gdf, columns: list[str] | None = None) -> dict:
    """What the conformance cases compare of a GeoDataFrame: attribute columns (or the values of
    ``columns`` only), row count (``nrow``), 2D geometry types, EPSG code and bounds."""
    import pandas as pd

    def plain(v):
        if v is None or (not isinstance(v, (list, dict)) and pd.isna(v)):
            return None
        return v.item() if hasattr(v, "item") else v

    attrs = [str(c) for c in gdf.columns if c != gdf.geometry.name]
    out: dict = {"columns": attrs} if columns is None else {}
    out["values"] = {c: [plain(v) for v in gdf[c]] for c in (attrs if columns is None else columns)}
    out["nrow"] = len(gdf)
    out["geometry_types"] = sorted({_GEOMETRY_TYPES.get(t.upper().replace(" Z", ""), t) for t in gdf.geom_type})
    out["crs"] = gdf.crs.to_epsg() if gdf.crs is not None else None
    out["bounds"] = [round(float(b), 6) for b in gdf.total_bounds]
    return out


def load_geodata(url_or_row: str | dict, *, layer: str | int | None = None, crs: Any = None,
                 max_mb: float | None = 200, max_features: int | None = 10_000):
    """Download a geodata distribution, or read a feature service, into a geopandas GeoDataFrame.

    Accepts a URL, or a row/dict from :func:`distributions`. Needs geopandas and pyogrio
    (``pip install 'dataeuropa[geo]'``); GDAL does the reading, so any vector format it knows
    works: GeoJSON, Shapefile, GeoPackage, KML/KMZ, GML, GPX, MapInfo TAB, FlatGeobuf, file
    geodatabase.

    ZIP archives (how shapefiles are published) are opened in place. Inside, the one geodata file
    is read (a .shp with its .dbf/.shx/.prj, .gpkg, .geojson, .kml, .gml, .gpx, .tab, .fgb, or a
    .gdb folder); if there are several, ``layer`` picks one by file name (without extension),
    otherwise ``ValueError`` lists them. Archives inside archives are not opened.

    ``layer`` picks a layer by name or 0-based position in files with several (GeoPackage, file
    geodatabase); by default the first is read, with a warning if there are more.

    The source coordinate reference system is kept. ``crs`` (e.g. ``"EPSG:4326"``) reprojects; a
    file without one (a shapefile without .prj) is read as stored, with a warning.

    Files over ``max_mb`` megabytes (default 200) are not downloaded; ``max_mb=None`` lifts the
    limit.

    Feature services are read too: WFS (``service=WFS`` URLs, WFS format ids) and OGC API
    Features (collection or landing-page URLs, OGCFEAT format ids). GDAL pages through the
    results. Each collection or feature type is a layer. At most ``max_features`` features
    (default 10,000) are read, with a warning when there are more; ``max_features=None`` reads all.

    Raises ``ValueError`` for other services (WMS, ...), web pages, HTML served instead of data,
    files or services GDAL cannot read, and checksum mismatches.
    """
    import re
    import tempfile

    row = {"url": url_or_row} if isinstance(url_or_row, str) else url_or_row
    url = row.get("url")
    if not url:
        raise ValueError("no URL available for this distribution")
    try:
        import geopandas  # noqa: F401
        import pyogrio  # noqa: F401
    except ImportError:
        raise ImportError("load_geodata needs geopandas and pyogrio: pip install 'dataeuropa[geo]'") from None
    source = _service_source(row.get("format"), url)
    if source is not None:
        return _read_source(source, layer, crs, max_features=max_features, what="the service")
    kind = _distribution_kind(row.get("format"), row.get("media_type"), url, row.get("download_url"))
    if kind == "service":
        raise ValueError(f"{url} is a service ({row.get('format')}) that load_geodata cannot read; "
                         f"it reads files, WFS and OGC API Features")
    if kind == "page":
        raise ValueError(f"{url} is a web page, not a file")
    ext = _geo_format(row.get("format"), row.get("media_type"), url) or _url_extension(url) or ""
    if not re.fullmatch(r"[A-Za-z0-9]{1,8}", ext):
        ext = "dat"
    limit = None if max_mb is None else int(max_mb * 1_000_000)
    with tempfile.TemporaryDirectory() as tmp:
        try:
            path = download(url_or_row, os.path.join(tmp, f"distribution.{ext.lower()}"), max_bytes=limit)
        except _TooLarge:
            raise ValueError(f"{url} is larger than {max_mb:g} MB; pass max_mb=None to load it anyway") from None
        return _read_geodata(path, layer, crs)


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
    return _get_json(f"{SEARCH_URL}/catalogues", cacheable=True)


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
