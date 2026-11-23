# load_geodata: geodata files into DataFrames with a geometry column, and the download size limit.

const GEO = joinpath(FIXTURES, "files", "geo")

geo_port, geo_sock = HTTP.Sockets.listenany(HTTP.Sockets.IPv4("127.0.0.1"), 18180)   # a free port
geo_server = HTTP.serve!("127.0.0.1", geo_port; server=geo_sock, verbose=false) do req
    path = joinpath(GEO, basename(HTTP.URI(req.target).path))
    isfile(path) ? HTTP.Response(200, read(path)) : HTTP.Response(404)
end
geo_url(name) = "http://127.0.0.1:$geo_port/$name"

@testset "geodata" begin
    df = load_geodata((url=geo_url("roads.zip"), format="SHP", media_type="application/zip"))
    @test df.name == ["A1", "A2"] && "geometry" in names(df)
    @test DE._geo_summary(df)["crs"] == 3763

    first_layer = @test_logs (:info, r"2 layers") match_mode=:any load_geodata(geo_url("layers.gpkg"))
    @test sort(names(first_layer)) == ["area", "code", "geometry"]   # GeoPackages call it `geom`, and have `fid`
    wells = load_geodata(geo_url("layers.gpkg"); layer=2, crs="EPSG:4326")
    @test nrow(wells) == 2 && DE._geo_summary(wells)["crs"] == 4326
    @test load_geodata(geo_url("two_shapes.zip"); layer="rivers").name == ["Tejo"]
    @test_throws "2 geodata files" load_geodata(geo_url("two_shapes.zip"))
    @test_throws "out of range" load_geodata(geo_url("layers.gpkg"); layer=3)

    noprj = @test_logs (:warn, r"no coordinate reference system") match_mode=:any load_geodata(geo_url("no_prj.zip"))
    @test DE._geo_summary(noprj)["crs"] === nothing
    @test_throws "cannot be reprojected" load_geodata(geo_url("no_prj.zip"); crs="EPSG:4326")

    @test_throws "larger than 0.0001 MB; pass max_mb=nothing" load_geodata(geo_url("layers.gpkg"); max_mb=0.0001)
    mktempdir() do tmp
        @test_throws "larger than the limit of 1,000 bytes" download_distribution(geo_url("layers.gpkg"),
                                                                                  joinpath(tmp, "x.gpkg"); max_bytes=1000)
        @test isempty(readdir(tmp))
        @test isfile(download_distribution(geo_url("points.geojson"), joinpath(tmp, "p.geojson"); max_bytes=10_000))
    end
    @test nrow(load_geodata(geo_url("points.geojson"); max_mb=nothing)) == 3

    @test_throws "is a service" load_geodata((url="https://example.org/wfs?service=WFS&request=GetCapabilities", format="WFS"))
    @test_throws "web page" load_geodata((url="https://example.org/map", format="HTML"))
end
close(geo_server)

LIVE && @testset "live geodata" begin
    found = false
    for id in search_datasets(; format="GEOJSON", limit=20).id
        files = filter(r -> uppercase(coalesce(r.format, "")) == "GEOJSON", distributions(id; files_only=true))
        nrow(files) == 0 && continue
        df = try
            load_geodata(files[1, :]; max_mb=20)
        catch
            continue   # dead links and oversized files are common; try the next dataset
        end
        @test "geometry" in names(df)
        found = true
        break
    end
    found || @info "no small, working GeoJSON distribution among the first results"
end
