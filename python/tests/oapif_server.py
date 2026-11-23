"""A minimal OGC API Features server for the tests: python oapif_server.py PORT.

Serves the collections in fixtures/files/oapif/*.geojson under /ogc, three features per page with
`next` links, as fixtures/README.md describes. It runs in its own process: GDAL holds Python's
global lock while it reads, so a server thread in the test process could not answer.
"""
import http.server
import json
import pathlib
import sys
from urllib.parse import parse_qs, urlsplit

DATA = pathlib.Path(__file__).resolve().parents[2] / "fixtures" / "files" / "oapif"
COLLECTIONS = {p.stem: json.loads(p.read_text(encoding="utf-8"))["features"] for p in sorted(DATA.glob("*.geojson"))}
PAGE = 3


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parts = urlsplit(self.path)
        query = {k: v[0] for k, v in parse_qs(parts.query).items()}
        base = f"http://127.0.0.1:{self.server.server_address[1]}/ogc"
        path = parts.path.rstrip("/")
        segs = path.split("/")[2:] if path.startswith("/ogc") else None
        body = None
        if segs == []:
            body = {"links": [{"href": f"{base}/collections", "rel": "data", "type": "application/json"}]}
        elif segs == ["collections"]:
            body = {"collections": [self.collection(base, c) for c in COLLECTIONS]}
        elif segs and len(segs) == 2 and segs[0] == "collections" and segs[1] in COLLECTIONS:
            body = self.collection(base, segs[1])
        elif segs and len(segs) == 3 and segs[0] == "collections" and segs[1] in COLLECTIONS and segs[2] == "items":
            features = COLLECTIONS[segs[1]]
            limit, offset = int(query.get("limit", PAGE)), int(query.get("offset", 0))
            page = features[offset:offset + min(limit, PAGE)]
            links = []
            if offset + len(page) < len(features):
                links.append({"href": f"{base}/collections/{segs[1]}/items?limit={limit}&offset={offset + len(page)}",
                              "rel": "next", "type": "application/geo+json"})
            body = {"type": "FeatureCollection", "features": page, "links": links, "numberMatched": len(features)}
        if body is None:
            self.send_error(404)
            return
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    @staticmethod
    def collection(base, name):
        return {"id": name, "title": name, "links": [
            {"href": f"{base}/collections/{name}/items", "rel": "items", "type": "application/geo+json"}]}

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
