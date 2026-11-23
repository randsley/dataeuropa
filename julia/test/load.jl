# load_distribution offline: Downloads.jl reads file:// URLs, so local files stand in for downloads.

const FILES = normpath(joinpath(@__DIR__, "..", "..", "fixtures", "files"))
fileurl(path) = "file://" * (Sys.iswindows() ? "/" * replace(path, '\\' => '/') : path)

if isdir(FILES)
    @testset "load_distribution" begin
        df = load_distribution((url=fileurl(joinpath(FILES, "semicolon.csv")), format="CSV", media_type=missing))
        @test names(df) == ["city", "population", "share"] && nrow(df) == 2
        @test names(load_distribution(fileurl(joinpath(FILES, "table.parquet")))) == ["id", "value", "label"]
        @test load_distribution(fileurl(joinpath(FILES, "table.xlsx")); sheet="Second").k == ["x", "y"]
        @test load_distribution(fileurl(joinpath(FILES, "table.xlsx")); sheet=2).k == ["x", "y"]
        @test load_distribution(fileurl(joinpath(FILES, "wrapped.json")); format="json").code == ["PT", "ES"]

        @test_throws "service" load_distribution((url="https://x.example/wms", format="WMS_SRVC"))
        @test_throws "archive" load_distribution((url="https://x.example/get", format="CSV", media_type="application/zip"))
        @test_throws "cannot tell" load_distribution("https://x.example/data")
        @test_throws "format must be" load_distribution("https://x.example/a.csv"; format="shapefile")
        @test_throws "no URL" load_distribution((url=missing,))
        mktempdir() do tmp
            write(joinpath(tmp, "page.csv"), "<!DOCTYPE html><html><body>Landing page</body></html>")
            @test_throws "HTML page" load_distribution(fileurl(joinpath(tmp, "page.csv")))
            write(joinpath(tmp, "zipped.csv"), UInt8[0x50, 0x4b, 0x03, 0x04, 0x00])
            @test_throws "archive" load_distribution(fileurl(joinpath(tmp, "zipped.csv")))
            write(joinpath(tmp, "list.json"), "[1, 2, 3]")
            @test_throws "not a table" load_distribution(fileurl(joinpath(tmp, "list.json")))
        end
    end
end

@testset "checksums" begin
    @test DataEuropa._checksum(Dict(:algorithm => "SHA-256", :checksum_value => " AB12 ")) == ("sha256", "ab12")
    @test DataEuropa._checksum(Dict(:algorithm => "http://spdx.org/rdf/terms#checksumAlgorithm_sha1",
                                    :checksum_value => "x")) == ("sha1", "x")
    @test DataEuropa._checksum(Dict(:checksum_value => "0"^40)) == ("sha1", "0"^40)
    @test DataEuropa._checksum(Dict(:checksum_value => "not-a-hash")) == (nothing, "not-a-hash")
    @test DataEuropa._checksum(Dict(:checksum_value => "")) == (nothing, nothing)
    @test DataEuropa._checksum(nothing) == (nothing, nothing)

    if isdir(FILES)
        src = joinpath(FILES, "comma.csv")
        good = DataEuropa._file_hash(src, "sha1")
        row = (url=fileurl(src), checksum=good, checksum_algorithm="sha1")
        mktempdir() do tmp
            @test endswith(download_distribution(row, tmp), "comma.csv")
            bad = merge(row, (checksum="0"^40,))
            @test_throws "checksum mismatch" download_distribution(bad, joinpath(tmp, "bad.csv"))
            @test !isfile(joinpath(tmp, "bad.csv"))                                  # deleted
            @test isfile(download_distribution(bad, joinpath(tmp, "kept.csv"); verify=false))
            @test isfile(download_distribution(merge(row, (checksum=missing, checksum_algorithm=missing)), joinpath(tmp, "a.csv")))
            @test isfile(download_distribution(merge(row, (checksum="1a2b", checksum_algorithm="crc")), joinpath(tmp, "b.csv")))
        end
        @test_throws "checksum mismatch" load_distribution((url=fileurl(joinpath(FILES, "semicolon.csv")), format="CSV",
                                                           checksum="0"^32, checksum_algorithm="md5"))
    end
end
