"""Response cache and resumable downloads."""
import http.server
import json
import threading

import pytest

import dataeuropa as de

live = pytest.mark.live


# ---------------------------------------------------------------- response cache

class _JsonResponse:
    def __init__(self, url, payload):
        self.url, self.status_code = url, 200
        self.content = json.dumps(payload).encode()

    def json(self):
        return json.loads(self.content)


@pytest.fixture
def calls(monkeypatch, tmp_path):
    """A fake session that records requests; the cache folder is temporary and starts off."""
    import dataeuropa.client as client

    seen = []

    class Session:
        def get(self, url, params=None, **kw):
            seen.append((url, dict(params or {})))
            if url.endswith("/catalogues"):
                return _JsonResponse(url, ["a", "b"])
            if "/datasets/" in url:
                return _JsonResponse(url, {"result": {"id": url.rsplit("/", 1)[-1], "distributions": []}})
            return _JsonResponse(url, {"result": {"count": 7, "results": [], "facets": []}})
    monkeypatch.setattr(client, "_get_session", lambda: Session())
    monkeypatch.setattr(client, "_cache_settings", {"on": None, "dir": None, "ttl": None})
    monkeypatch.delenv("DATAEUROPA_CACHE", raising=False)
    monkeypatch.delenv("DATAEUROPA_CACHE_TTL", raising=False)
    monkeypatch.setenv("DATAEUROPA_CACHE_DIR", str(tmp_path / "cache"))
    return seen


def test_cache_off_by_default(calls):
    de.catalogues()
    de.catalogues()
    assert len(calls) == 2


def test_cache_serves_repeat_requests(calls, tmp_path):
    assert de.cache_on() == str(tmp_path / "cache")
    for _ in range(2):
        assert de.catalogues() == ["a", "b"]
        assert de.get_dataset("x1", raw=True)["id"] == "x1"
        assert de.count("water") == 7                      # limit=0: cacheable
        de.search("water", limit=5)                        # returns records: never cached
    urls = [u for u, _ in calls]
    assert urls.count(f"{de.SEARCH_URL}/catalogues") == 1
    assert urls.count(f"{de.SEARCH_URL}/datasets/x1") == 1
    assert [p["limit"] for u, p in calls if u.endswith("/search")] == [0, 5, 5]
    de.count("other")                                      # other parameters: a new entry
    assert len(calls) == 6
    assert de.clear_cache() == 4
    de.catalogues()
    assert len(calls) == 7
    de.cache_off()
    de.catalogues()
    assert len(calls) == 8


def test_cache_time_limit(calls):
    de.cache_on(ttl=0)                                     # every entry is already too old
    de.catalogues()
    de.catalogues()
    assert len(calls) == 2


def test_cache_from_environment(calls, monkeypatch):
    monkeypatch.setenv("DATAEUROPA_CACHE", "1")
    de.catalogues()
    de.catalogues()
    assert len(calls) == 1


# ---------------------------------------------------------------- resumable downloads

@pytest.fixture
def server():
    """A local HTTP server for one file, with ranges, Last-Modified and If-Range like a real host.
    Change ``state["body"]`` / ``state["modified"]`` to change the file; ``state["ranges"]``
    records the Range header of each request."""
    state = {"body": bytes(range(256)) * 40, "modified": "Thu, 11 Sep 2025 12:19:52 GMT", "ranges": []}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body, rng = state["body"], self.headers.get("Range")
            state["ranges"].append(rng)
            if rng and self.headers.get("If-Range") in (None, state["modified"]):
                start = int(rng.split("=")[1].rstrip("-"))
                if start >= len(body):
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{len(body)}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{len(body) - 1}/{len(body)}")
                body = body[start:]
            else:
                self.send_response(200)
            self.send_header("Last-Modified", state["modified"])
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    state["url"] = f"http://127.0.0.1:{srv.server_address[1]}/data.bin"
    yield state
    srv.shutdown()


def interrupted(folder, state, n, name="data.bin"):
    """Leave the first ``n`` bytes as a partial download, as an interrupted call would."""
    (folder / f"{name}.part").write_bytes(state["body"][:n])
    (folder / f"{name}.part.json").write_text(json.dumps({"url": state["url"], "validator": state["modified"]}))


def test_download_writes_no_leftovers(server, tmp_path):
    path = de.download(server["url"], tmp_path)
    assert open(path, "rb").read() == server["body"]
    assert sorted(p.name for p in tmp_path.iterdir()) == ["data.bin"]


def test_download_resumes(server, tmp_path):
    interrupted(tmp_path, server, 1000)
    path = de.download(server["url"], tmp_path)
    assert open(path, "rb").read() == server["body"]
    assert server["ranges"] == ["bytes=1000-"]
    assert sorted(p.name for p in tmp_path.iterdir()) == ["data.bin"]


def test_download_restarts_when_file_changed(server, tmp_path):
    interrupted(tmp_path, server, 1000)
    server["modified"] = "Fri, 12 Sep 2025 08:00:00 GMT"
    server["body"] = b"new content" * 100
    path = de.download(server["url"], tmp_path)
    assert open(path, "rb").read() == server["body"]       # the server sent all of the new file


def test_download_restarts_on_bad_range(server, tmp_path):
    interrupted(tmp_path, server, 1000)
    server["body"] = server["body"][:500]                  # now shorter than the partial file
    path = de.download(server["url"], tmp_path)
    assert open(path, "rb").read() == server["body"]
    assert server["ranges"] == ["bytes=1000-", None]       # 416, then from the start


def test_download_resume_off(server, tmp_path):
    interrupted(tmp_path, server, 1000)
    path = de.download(server["url"], tmp_path, resume=False)
    assert open(path, "rb").read() == server["body"]
    assert server["ranges"] == [None]


def test_download_ignores_part_of_another_url(server, tmp_path):
    interrupted(tmp_path, dict(server, url="http://elsewhere.example/data.bin"), 1000)
    path = de.download(server["url"], tmp_path)
    assert open(path, "rb").read() == server["body"]
    assert server["ranges"] == [None]


@live
def test_live_resume_with_checksum(tmp_path):
    # Resume the dados.gov.pt CSV from half way; its SHA-1 checksum proves the result is exact.
    import requests

    dist = de.distributions("68c2be5c43136b247fe74d41")
    row = dist[dist.checksum_algorithm == "sha1"].iloc[0]
    data = open(de.download(row, tmp_path / "whole.csv"), "rb").read()
    lm = requests.head(row.url, allow_redirects=True, timeout=60).headers.get("last-modified")
    assert lm, "the host no longer sends Last-Modified; pick another file"
    (tmp_path / "half.csv.part").write_bytes(data[: len(data) // 2])
    (tmp_path / "half.csv.part.json").write_text(json.dumps({"url": row.url, "validator": lm}))
    assert open(de.download(row, tmp_path / "half.csv"), "rb").read() == data
