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

    @test_throws "cannot read; it reads files, WFS and OGC API Features" load_geodata(
        (url="https://example.org/wms?service=WMS&request=GetCapabilities", format="WMS"))
    @test_throws "web page" load_geodata((url="https://example.org/map", format="HTML"))
end
close(geo_server)

# The OGC API Features test server (oapif_server.jl), in its own process: a GDAL call blocks this
# process's only thread, so a server task here could not answer.
oapif_port = let (p, s) = HTTP.Sockets.listenany(HTTP.Sockets.IPv4("127.0.0.1"), 18280)
    close(s)
    Int(p)
end
oapif_proc = run(pipeline(`$(Base.julia_cmd()) --project=$(dirname(Base.active_project())) $(joinpath(@__DIR__, "oapif_server.jl")) $oapif_port`;
                          stdout=devnull), wait=false)
oapif = "http://127.0.0.1:$oapif_port/ogc"
oapif_ready = false
for _ in 1:240   # wait up to 2 minutes for Julia to start and load HTTP
    try
        HTTP.get(oapif; readtimeout=2, retry=false)
        global oapif_ready = true
        break
    catch
        process_running(oapif_proc) || break
        sleep(0.5)
    end
end

@testset "picking layers" begin
    wfs = ["ns:roads", "ns:Rivers", "other:rivers"]
    @test DE._pick_layer(wfs, "roads") == "ns:roads" && DE._pick_layer(wfs, "NS:ROADS") == "ns:roads"
    @test_throws "no layer \"rivers\"; the service has" DE._pick_layer(wfs, "rivers", "the service")
    @test (@test_logs (:info, r"the service has 3 layers") DE._pick_layer(wfs, nothing, "the service")) == "ns:roads"
end

@testset "feature services" begin
    @test oapif_ready
    if oapif_ready
        df = load_geodata((url="$oapif/collections/places", format="OGCFEAT"))
        @test nrow(df) == 7 && df.name[1:2] == ["P1", "P2"] && DE._geo_summary(df)["crs"] == 4326
        landing = @test_logs (:info, r"2 layers") match_mode=:any load_geodata((url=oapif, format="OGCFEAT"))
        @test nrow(landing) == 7
        roads = load_geodata("$oapif/collections/roads/items?f=json"; layer=1, crs="EPSG:3035")
        @test nrow(roads) == 2 && DE._geo_summary(roads)["crs"] == 3035
        @test nrow(load_geodata((url=oapif, format="OGCFEAT"); layer="roads")) == 2
        # The collection description stays whole JSON, on both read paths (GeoDataFrames alone
        # drops it with a warning, or cuts it at the first "=").
        for kw in ((; max_features=nothing), (; max_features=7))
            t = @test_logs min_level=Base.CoreLogging.Info load_geodata("$oapif/collections/places?f=json"; kw...) # no warnings
            @test DE.JSON3.read(metadata(t, "json:metadata")).id == "places"
        end

        limited = @test_logs (:warn, r"more than 4 features; read the first 4") match_mode=:any load_geodata(
            "$oapif/collections/places"; max_features=4)
        @test limited.id == 1:4 && "geometry" in names(limited) && DE._geo_summary(limited)["crs"] == 4326
        @test nrow(@test_logs load_geodata("$oapif/collections/places"; max_features=7)) == 7
        @test nrow(@test_logs load_geodata("$oapif/collections/places"; max_features=nothing)) == 7
    end
end
kill(oapif_proc)

LIVE && @testset "live feature services" begin
    for fmt in ("WFS_SRVC", "OGCFEAT")
        found = false
        for id in search_datasets(; format=fmt, limit=20).id
            for row in eachrow(distributions(id))
                DE._service_source(row.format, row.url) === nothing && continue
                df = try
                    Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                        load_geodata(row; max_features=20)
                    end
                catch
                    continue   # unreachable hosts and broken services are common; try the next one
                end
                @test "geometry" in names(df) && 0 < nrow(df) <= 20
                found = true
                break
            end
            found && break
        end
        found || @info "no working $fmt service among the first results"
    end
end

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
