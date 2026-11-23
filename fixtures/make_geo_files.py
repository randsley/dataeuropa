"""Write the sample geodata files in fixtures/files/geo/ (needs geopandas and pyogrio).

Small files in the formats load_geodata reads, plus archives that exercise its rules. The files
are committed; re-run only to change them, then run make_expected.py.
"""
from __future__ import annotations

import io
import pathlib
import shutil
import tempfile
import zipfile

import geopandas as gpd
from shapely.geometry import LineString, Point, Polygon

OUT = pathlib.Path(__file__).resolve().parent / "files" / "geo"

KML = """<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document>
  <name>places</name>
  <Placemark>
    <name>Lisboa</name>
    <description>Capital</description>
    <Point><coordinates>-9.1393,38.7223,0</coordinates></Point>
  </Placemark>
  <Placemark>
    <name>Porto</name>
    <description>North</description>
    <Point><coordinates>-8.6291,41.1579,0</coordinates></Point>
  </Placemark>
</Document>
</kml>
"""


def write_zip(path: pathlib.Path, files: dict[str, bytes]) -> None:
    """A ZIP with fixed timestamps, so re-running gives the same bytes."""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data)


def shapefile_bytes(gdf: gpd.GeoDataFrame, name: str, with_prj: bool = True) -> dict[str, bytes]:
    """The files of a shapefile called `name`, as {file name: bytes}."""
    with tempfile.TemporaryDirectory() as tmp:
        gdf.to_file(pathlib.Path(tmp) / f"{name}.shp", engine="pyogrio")
        out = {}
        for f in sorted(pathlib.Path(tmp).iterdir()):
            if f.suffix.lower() in (".shp", ".shx", ".dbf", ".prj", ".cpg") and (with_prj or f.suffix != ".prj"):
                out[f.name] = f.read_bytes()
        return out


def main() -> None:
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)

    points = gpd.GeoDataFrame(
        {"id": [1, 2, 3], "name": ["Lisboa", "Porto", "Faro"], "value": [3.5, None, 10.0]},
        geometry=[Point(-9.1393, 38.7223), Point(-8.6291, 41.1579), Point(-7.9304, 37.0194)], crs="EPSG:4326")
    points.to_file(OUT / "points.geojson", driver="GeoJSON", engine="pyogrio")

    # Two roads in Portugal's national grid (ETRS89 / PT-TM06).
    roads = gpd.GeoDataFrame(
        {"id": [1, 2], "name": ["A1", "A2"]},
        geometry=[LineString([(-90000, -100000), (-85000, -95000), (-80000, -90000)]),
                  LineString([(-50000, -250000), (-45000, -260000)])], crs="EPSG:3763")
    rivers = gpd.GeoDataFrame(
        {"id": [1], "name": ["Tejo"]},
        geometry=[LineString([(-100000, -110000), (-60000, -105000)])], crs="EPSG:3763")
    write_zip(OUT / "roads.zip", {"data/" + k: v for k, v in shapefile_bytes(roads, "roads").items()}
              | {"data/README.txt": b"Roads sample.\n", "__MACOSX/data/._roads.shp": b"junk"})
    write_zip(OUT / "two_shapes.zip", shapefile_bytes(roads, "roads") | shapefile_bytes(rivers, "rivers"))
    write_zip(OUT / "no_prj.zip", shapefile_bytes(roads, "roads", with_prj=False))
    write_zip(OUT / "no_geo.zip", {"README.txt": b"Nothing to map here.\n"})

    # A GeoPackage with two layers, in the European grid (ETRS89-LAEA).
    parcels = gpd.GeoDataFrame(
        {"code": ["P1", "P2"], "area": [1250.5, 980.0]},
        geometry=[Polygon([(2700000, 1700000), (2700100, 1700000), (2700100, 1700100), (2700000, 1700000)]),
                  Polygon([(2701000, 1701000), (2701050, 1701000), (2701050, 1701080), (2701000, 1701000)])],
        crs="EPSG:3035")
    wells = gpd.GeoDataFrame({"depth": [12.5, 40.0]},
                             geometry=[Point(2700050, 1700020), Point(2701010, 1701030)], crs="EPSG:3035")
    parcels.to_file(OUT / "layers.gpkg", layer="parcels", driver="GPKG", engine="pyogrio")
    wells.to_file(OUT / "layers.gpkg", layer="wells", driver="GPKG", engine="pyogrio", mode="a")

    (OUT / "places.kml").write_bytes(KML.encode("utf-8"))
    write_zip(OUT / "places.kmz", {"doc.kml": KML.encode("utf-8"), "files/icon.txt": b"not an image"})

    # GML as published: no .xsd next to it, so readers infer the field types.
    with tempfile.TemporaryDirectory() as tmp:
        points.to_crs("EPSG:25829").to_file(pathlib.Path(tmp) / "features.gml", driver="GML", engine="pyogrio")
        shutil.copy(pathlib.Path(tmp) / "features.gml", OUT / "features.gml")

    for f in sorted(OUT.iterdir()):
        print(f"wrote {f.relative_to(OUT.parent.parent.parent)} ({f.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
