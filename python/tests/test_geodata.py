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
    with pytest.raises(ValueError, match="is a service"):
        de.load_geodata({"url": "https://example.org/wfs?service=WFS&request=GetCapabilities", "format": "WFS"})
    with pytest.raises(ValueError, match="web page"):
        de.load_geodata({"url": "https://example.org/map", "format": "HTML"})


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
