# Worked examples

Three tasks from start to finish. The same examples are in the
[Python](https://randsley.github.io/dataeuropa/python/examples/) and
[R](https://randsley.github.io/dataeuropa/r/articles/examples.html) documentation.

The outputs shown were taken in November 2026. The portal changes all the time, so counts and
search results will differ when you run the code.

## 1. Air quality in Lisbon: from a search to a summary table

Find air-quality data from Portugal that comes as CSV. Quotes make the search match the phrase,
not the separate words.

```julia
using DataEuropa, DataFrames, Statistics

hits = search_datasets("\"air quality\""; country="pt", format="CSV")
hits[:, [:id, :title, :publisher]]
```

```text
2×3 DataFrame
 Row │ id                        title                              publisher
     │ String                    String                             String
─────┼─────────────────────────────────────────────────────────────────────────────────────────
   1 │ 67a5e928a3ee7360b61cd5e4  Sensing: Monthly reports with Ai…  Câmara Municipal de Oeiras
   2 │ 6689f1686e4bd9bc98ed011b  Monitoring of Environmental Para…  Município de Lisboa
```

The Lisbon dataset has one file per period: `QA` files hold air quality, `ME` files weather. List
the files only (no services or web pages):

```julia
files = distributions("6689f1686e4bd9bc98ed011b"; files_only=true)
files[:, [:title, :format]]
```

```text
11×2 DataFrame
 Row │ title       format
     │ String      String
─────┼────────────────────
   1 │ ME_2024_S1  CSV
   2 │ QA_2023     ZIP
  ⋮  │     ⋮         ⋮
   6 │ QA_2024_Q1  CSV
  ⋮  │     ⋮         ⋮
```

Read the first quarter of 2024 into a data frame. `load_distribution` takes a row of the table
and checks the file's checksum when the portal has one.

```julia
qa = load_distribution(files[findfirst(isequal("QA_2024_Q1"), files.title), :])
first(qa[:, [:DTM_LOCAL, :PARAMETRO, :LOCAL, :UNIDADE, :VALOR]], 3)
```

```text
3×5 DataFrame
 Row │ DTM_LOCAL              PARAMETRO  LOCAL             UNIDADE  VALOR
     │ String                 String     String            String   Float64
─────┼──────────────────────────────────────────────────────────────────────
   1 │ 2024-01-05 19:00:00.0  PM25       Calçada da Ajuda  µg/m3        6.0
   2 │ 2024-01-06 03:00:00.0  PM25       Calçada da Ajuda  µg/m3        5.0
   3 │ 2024-01-06 04:00:00.0  PM25       Calçada da Ajuda  µg/m3        3.0
```

The file is in long format: one row per reading, with the pollutant in `PARAMETRO`. `-99` marks a
missing reading. Some stations have only a few readings, so count them too and keep the stations
with at least 300 before comparing NO₂ means:

```julia
no2 = filter(r -> r.PARAMETRO == "NO2" && coalesce(r.VALOR >= 0, false), qa)
by_station = combine(groupby(no2, :LOCAL), :VALOR => mean => :mean, nrow => :count)
first(sort(filter(:count => >=(300), by_station), :mean; rev=true), 5)
```

```text
5×3 DataFrame
 Row │ LOCAL                              mean      count
     │ String                             Float64   Int64
─────┼────────────────────────────────────────────────────
   1 │ Avenida António Augusto de Aguiar  111.935     356
   2 │ Campo de Ourique                    95.3343    356
   3 │ Praça São Francisco de Assis        93.9466    356
   4 │ Rua Morais Soares                   91.9579    356
   5 │ Estrada de Monsanto                 77.9803    356
```

Without the count filter, a station with 35 readings (one of them 564) would come first.

## 2. Who publishes air-quality data, and in what formats

Counts and facets need no records, so they are fast (and cached when `cache_on()` is set).

```julia
count_datasets("\"air quality\"")                     # 3583
facet_values("country", "\"air quality\""; top=8)
```

```text
8×3 DataFrame
 Row │ id      label           count
     │ String  String          Int64
─────┼───────────────────────────────
   1 │ EUROPE  Europe            621
   2 │ de      Germany           538
   3 │ fr      France            449
   4 │ gb      United Kingdom    372
   5 │ es      Spain             347
   6 │ it      Italy             247
   7 │ ro      Romania           189
   8 │ bg      Bulgaria          147
```

`EUROPE` is the value for datasets about Europe as a whole. Formats:

```julia
facet_values("format", "\"air quality\""; top=6)
```

```text
6×3 DataFrame
 Row │ id        label   count
     │ String    String  Int64
─────┼─────────────────────────
   1 │ CSV       CSV       868
   2 │ JSON      JSON      536
   3 │ XML       XML       391
   4 │ WMS_SRVC  WMS       245
   5 │ ZIP       ZIP       172
   6 │ HTML      HTML      145
```

Use the `id` column in filters: `search_datasets("\"air quality\""; format="WMS_SRVC")`. A dataset
with several formats counts once for each, so format counts can add up to more than the total.

## 3. Boundaries of Gelsenkirchen from a feature service

The city of Gelsenkirchen publishes its administrative boundaries as a GeoServer service, which
the portal lists as OGC API Features and as WFS. This needs GeoDataFrames.jl
(`Pkg.add("GeoDataFrames")`), loaded next to DataEuropa.

```julia
using GeoDataFrames

dists = distributions("eac1e504-9d63-4670-95b3-3ef04e22aa6e~~1")
dists[:, [:format, :kind]]
```

```text
3×2 DataFrame
 Row │ format    kind
     │ String    String
─────┼───────────────────
   1 │ OGCFEAT   service
   2 │ JSON      file
   3 │ WFS_SRVC  service
```

The OGC API Features entry points to one collection, the cadastral districts. The data comes in
ETRS89 / UTM zone 32N (EPSG:25832), which is in metres, so areas can be computed directly:

```julia
districts = load_geodata(dists[findfirst(isequal("OGCFEAT"), dists.format), :])
districts.area_km2 = round.(GeoDataFrames.AG.geomarea.(districts.geometry) ./ 1e6; digits=2)
first(sort(districts[:, [:gemarkung_name, :area_km2]], :area_km2; rev=true), 3)
```

```text
3×2 DataFrame
 Row │ gemarkung_name  area_km2
     │ String          Float64
─────┼──────────────────────────
   1 │ Buer               61.29
   2 │ Bismarck           10.08
   3 │ Heßler              6.88
```

The WFS entry is the whole service, with 22 layers. Without `layer=`, `load_geodata` reads the
first and logs the full list. Pick the city quarters by name; the namespace prefix
(`verwaltungsgrenzen:`) can be left out. `crs=` reprojects, here to longitude and latitude:

```julia
quarters = load_geodata(dists[findfirst(isequal("WFS_SRVC"), dists.format), :];
                        layer="stadtteil", crs="EPSG:4326")
nrow(quarters)                                        # 18
```

Services can be large, so `load_geodata` reads at most 10,000 features and warns when there are
more. Pass `max_features=nothing` to read all of them.
