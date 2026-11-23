"""load_geodata: geodata files into GeoDataFrames, and the download size limit."""
import http.server
import pathlib
import threading
import warnings

import pytest

import dataeuropa as de

geopandas = pytest.importorskip("geopandas")
pytest.importorskip("pyogrio")

GEO = pathlib.Path(__file__).resolve().parents[2] / "fixtures" / "files" / "geo"


class _Handler(http.server.BaseHTTPRequestHandler):
    """Serves fixtures/files/geo/<name>. With ?nolength the size is not announced (the body ends
    when the connection closes), so a size limit must be enforced while streaming."""
    protocol_version = "HTTP/1.0"

    def do_GET(self):
        name, _, query = self.path.lstrip("/").partition("?")
        path = GEO / name
        if not path.is_file():
            self.send_error(404)
            return
        body = path.read_bytes()
        self.send_response(200)
        if query != "nolength":
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


@pytest.fixture(scope="module")
def server():
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{httpd.server_address[1]}"
    httpd.shutdown()


def test_zipped_shapefile_from_a_row(server):
    gdf = de.load_geodata({"url": f"{server}/roads.zip", "format": "SHP", "media_type": "application/zip"})
    assert isinstance(gdf, geopandas.GeoDataFrame)
    assert list(gdf["name"]) == ["A1", "A2"] and gdf.crs.to_epsg() == 3763


def test_layers_and_reprojection(server):
    with pytest.warns(UserWarning, match="2 layers"):
        first = de.load_geodata(f"{server}/layers.gpkg")
    assert list(first.columns) == ["code", "area", "geometry"]
    wells = de.load_geodata(f"{server}/layers.gpkg", layer=1, crs="EPSG:4326")
    assert len(wells) == 2 and wells.crs.to_epsg() == 4326
    assert de.load_geodata(f"{server}/two_shapes.zip", layer="rivers")["name"].tolist() == ["Tejo"]
    with pytest.raises(ValueError, match="2 geodata files"):
        de.load_geodata(f"{server}/two_shapes.zip")
    with pytest.raises(ValueError, match="out of range"):
        de.load_geodata(f"{server}/layers.gpkg", layer=2)


def test_missing_crs_warns(server):
    with pytest.warns(UserWarning, match="no coordinate reference system"):
        gdf = de.load_geodata(f"{server}/no_prj.zip")
    assert gdf.crs is None
    with pytest.raises(ValueError, match="cannot be reprojected"):
        de.load_geodata(f"{server}/no_prj.zip", crs="EPSG:4326")


def test_size_limit(server, tmp_path):
    with pytest.raises(ValueError, match="larger than 0.0001 MB; pass max_mb=None"):
        de.load_geodata(f"{server}/layers.gpkg", max_mb=0.0001)
    for query in ("", "?nolength"):  # announced size, then a stream that runs over
        with pytest.raises(ValueError, match="larger than the limit of 1,000 bytes"):
            de.download(f"{server}/layers.gpkg{query}", tmp_path / "x.gpkg", max_bytes=1000)
        assert list(tmp_path.iterdir()) == []
    assert de.download(f"{server}/points.geojson?nolength", tmp_path / "p.geojson", max_bytes=10_000)
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        assert len(de.load_geodata(f"{server}/points.geojson", max_mb=None)) == 3


def test_refusals():
    with pytest.raises(ValueError, match="cannot read; it reads files, WFS and OGC API Features"):
        de.load_geodata({"url": "https://example.org/wms?service=WMS&request=GetCapabilities", "format": "WMS"})
    with pytest.raises(ValueError, match="web page"):
        de.load_geodata({"url": "https://example.org/map", "format": "HTML"})


@pytest.fixture(scope="module")
def oapif():
    """The OGC API Features test server (tests/oapif_server.py), in its own process."""
    import socket
    import subprocess
    import sys
    import time

    import requests

    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    proc = subprocess.Popen([sys.executable, str(pathlib.Path(__file__).with_name("oapif_server.py")), str(port)])
    base = f"http://127.0.0.1:{port}/ogc"
    for _ in range(100):
        try:
            requests.get(base, timeout=1)
            break
        except requests.ConnectionError:
            time.sleep(0.1)
    yield base
    proc.kill()


def test_ogc_api_features(oapif):
    gdf = de.load_geodata({"url": f"{oapif}/collections/places", "format": "OGCFEAT"})
    assert len(gdf) == 7 and list(gdf["name"])[:2] == ["P1", "P2"] and gdf.crs.to_epsg() == 4326
    with pytest.warns(UserWarning, match="2 layers"):
        assert len(de.load_geodata({"url": oapif, "format": "OGCFEAT"})) == 7      # landing page: first collection
    roads = de.load_geodata(f"{oapif}/collections/roads/items?f=json", layer=0, crs="EPSG:3035")
    assert len(roads) == 2 and roads.crs.to_epsg() == 3035
    assert len(de.load_geodata({"url": oapif, "format": "OGCFEAT"}, layer="roads")) == 2


def test_feature_limit(oapif):
    with pytest.warns(UserWarning, match="more than 4 features; read the first 4"):
        gdf = de.load_geodata(f"{oapif}/collections/places", max_features=4)
    assert list(gdf["id"]) == [1, 2, 3, 4]
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        assert len(de.load_geodata(f"{oapif}/collections/places", max_features=7)) == 7
        assert len(de.load_geodata(f"{oapif}/collections/places", max_features=None)) == 7


@pytest.mark.live
@pytest.mark.parametrize("fmt", ["WFS_SRVC", "OGCFEAT"])
def test_live_service(fmt):
    for dataset_id in de.search_datasets(facets={"format": [fmt]}, limit=20)["id"]:
        for row in de.distributions(dataset_id).to_dict("records"):
            if not de.client._service_source(row["format"], row["url"]):
                continue
            try:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore")
                    gdf = de.load_geodata(row, max_features=20)
            except ValueError:
                continue  # unreachable hosts and broken services are common; try the next one
            assert isinstance(gdf, geopandas.GeoDataFrame) and 0 < len(gdf) <= 20
            return
    pytest.skip(f"no working {fmt} service among the first results")


@pytest.mark.live
def test_live_geojson():
    rows = de.search_datasets(facets={"format": ["GEOJSON"]}, limit=20)
    for dataset_id in rows["id"]:
        files = de.distributions(dataset_id, files_only=True)
        files = files[files["format"].str.upper() == "GEOJSON"]
        if len(files):
            try:
                gdf = de.load_geodata(files.iloc[0].to_dict(), max_mb=20)
            except (ValueError, OSError):
                continue  # dead links and oversized files are common; try the next dataset
            assert isinstance(gdf, geopandas.GeoDataFrame) and gdf.geometry.name == "geometry"
            return
    pytest.skip("no small, working GeoJSON distribution among the first results")
