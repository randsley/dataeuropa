# Worked examples

Three tasks from start to finish. The same examples are in the
[Julia](https://randsley.github.io/dataeuropa/julia/examples/) and
[R](https://randsley.github.io/dataeuropa/r/articles/examples.html) documentation.

The outputs shown were taken in November 2026. The portal changes all the time, so counts and
search results will differ when you run the code.

## 1. Air quality in Lisbon: from a search to a summary table

Find air-quality data from Portugal that comes as CSV. Quotes make the search match the phrase,
not the separate words.

```python
import dataeuropa as de

hits = de.search_datasets('"air quality"', country="pt", format="CSV")
hits[["id", "title", "publisher"]]
```

```text
                         id                                              title                   publisher
0  67a5e928a3ee7360b61cd5e4  Sensing: Monthly reports with Air Quality, Sou...  Câmara Municipal de Oeiras
1  6689f1686e4bd9bc98ed011b  Monitoring of Environmental Parameters of the ...         Município de Lisboa
```

The Lisbon dataset has one file per period: `QA` files hold air quality, `ME` files weather. List
the files only (no services or web pages):

```python
files = de.distributions("6689f1686e4bd9bc98ed011b", files_only=True)
files[["title", "format"]]
```

```text
         title format
0   ME_2024_S1    CSV
1      QA_2023    ZIP
...
5   QA_2024_Q1    CSV
...
```

Read the first quarter of 2024 into a data frame. `load_distribution` takes a row of the table
and checks the file's checksum when the portal has one.

```python
qa = de.load_distribution(files[files["title"] == "QA_2024_Q1"].iloc[0])
qa[["DTM_LOCAL", "PARAMETRO", "LOCAL", "UNIDADE", "VALOR"]].head(3)
```

```text
               DTM_LOCAL PARAMETRO             LOCAL UNIDADE  VALOR
0  2024-01-05 19:00:00.0      PM25  Calçada da Ajuda   µg/m3    6.0
1  2024-01-06 03:00:00.0      PM25  Calçada da Ajuda   µg/m3    5.0
2  2024-01-06 04:00:00.0      PM25  Calçada da Ajuda   µg/m3    3.0
```

The file is in long format: one row per reading, with the pollutant in `PARAMETRO`. `-99` marks a
missing reading. Some stations have only a few readings, so count them too and keep the stations
with at least 300 before comparing NO₂ means:

```python
no2 = qa[(qa["PARAMETRO"] == "NO2") & (qa["VALOR"] >= 0)]
by_station = no2.groupby("LOCAL")["VALOR"].agg(["mean", "count"])
by_station[by_station["count"] >= 300].nlargest(5, "mean").round(1)
```

```text
                                    mean  count
LOCAL
Avenida António Augusto de Aguiar  111.9    356
Campo de Ourique                    95.3    356
Praça São Francisco de Assis        93.9    356
Rua Morais Soares                   92.0    356
Estrada de Monsanto                 78.0    356
```

Without the count filter, a station with 35 readings (one of them 564) would come first.

## 2. Who publishes air-quality data, and in what formats

Counts and facets need no records, so they are fast (and cached when `cache_on()` is set).

```python
de.count('"air quality"')                              # 3583
de.facet_values("country", '"air quality"', top=8)
```

```text
       id           label  count
0  EUROPE          Europe    621
1      de         Germany    538
2      fr          France    449
3      gb  United Kingdom    372
4      es           Spain    347
5      it           Italy    247
6      ro         Romania    189
7      bg        Bulgaria    147
```

`EUROPE` is the value for datasets about Europe as a whole. Formats:

```python
de.facet_values("format", '"air quality"', top=6)
```

```text
         id label  count
0       CSV   CSV    868
1      JSON  JSON    536
2       XML   XML    391
3  WMS_SRVC   WMS    245
4       ZIP   ZIP    172
5      HTML  HTML    145
```

Use the `id` column in filters: `de.search_datasets('"air quality"', format="WMS_SRVC")`. A dataset
with several formats counts once for each, so format counts can add up to more than the total.

## 3. Boundaries of Gelsenkirchen from a feature service

The city of Gelsenkirchen publishes its administrative boundaries as a GeoServer service, which
the portal lists as OGC API Features and as WFS. This needs the `geo` extra
(`pip install "dataeuropa[geo]"`).

```python
dists = de.distributions("eac1e504-9d63-4670-95b3-3ef04e22aa6e~~1")
dists[["format", "kind"]]
```

```text
     format     kind
0   OGCFEAT  service
1      JSON     file
2  WFS_SRVC  service
```

The OGC API Features entry points to one collection, the cadastral districts. The data comes in
ETRS89 / UTM zone 32N (EPSG:25832), which is in metres, so areas can be computed directly:

```python
districts = de.load_geodata(dists[dists["format"] == "OGCFEAT"].iloc[0])
districts["area_km2"] = (districts.area / 1e6).round(2)
districts[["gemarkung_name", "area_km2"]].sort_values("area_km2", ascending=False).head(3)
```

```text
  gemarkung_name  area_km2
5           Buer     61.29
4       Bismarck     10.08
9         Heßler      6.88
```

The WFS entry is the whole service, with 22 layers. Without `layer=`, `load_geodata` reads the
first and warns with the full list. Pick the city quarters by name; the namespace prefix
(`verwaltungsgrenzen:`) can be left out. `crs=` reprojects, here to longitude and latitude:

```python
quarters = de.load_geodata(dists[dists["format"] == "WFS_SRVC"].iloc[0],
                           layer="stadtteil", crs="EPSG:4326")
len(quarters)                                          # 18
quarters.plot()                                        # needs matplotlib
```

Services can be large, so `load_geodata` reads at most 10,000 features and warns when there are
more. Pass `max_features=None` to read all of them.
