# A minimal OGC API Features server for the tests: julia --project oapif_server.jl PORT
#
# Serves the collections in fixtures/files/oapif/*.geojson under /ogc, three features per page with
# `next` links, as fixtures/README.md describes. It runs in its own process: a GDAL call blocks the
# test process's only thread, so a server task there could not answer.

using HTTP, JSON3

const DATA = normpath(joinpath(@__DIR__, "..", "..", "fixtures", "files", "oapif"))
const COLLECTIONS = Dict(first(splitext(f)) => JSON3.read(read(joinpath(DATA, f), String)).features
                         for f in readdir(DATA) if endswith(f, ".geojson"))
const PAGE = 3
const PORT = parse(Int, ARGS[1])
const BASE = "http://127.0.0.1:$PORT/ogc"

json(x) = HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(x))
collection(name) = Dict("id" => name, "title" => name, "links" => [
    Dict("href" => "$BASE/collections/$name/items", "rel" => "items", "type" => "application/geo+json")])

function handle(req)
    uri = HTTP.URI(req.target)
    query = HTTP.queryparams(uri)
    path = rstrip(uri.path, '/')
    notfound = HTTP.Response(404, ["Content-Type" => "application/json"], """{"code": "NotFound"}""")
    (path == "/ogc" || startswith(path, "/ogc/")) || return notfound
    segs = split(path[5:end], '/'; keepempty=false)
    isempty(segs) && return json(Dict("links" => [Dict("href" => "$BASE/collections", "rel" => "data",
                                                       "type" => "application/json")]))
    segs == ["collections"] && return json(Dict("collections" => [collection(n) for n in sort(collect(keys(COLLECTIONS)))]))
    if length(segs) >= 2 && segs[1] == "collections" && haskey(COLLECTIONS, segs[2])
        name = String(segs[2])
        length(segs) == 2 && return json(collection(name))
        if length(segs) == 3 && segs[3] == "items"
            features = COLLECTIONS[name]
            limit = parse(Int, get(query, "limit", string(PAGE)))
            offset = parse(Int, get(query, "offset", "0"))
            page = features[offset+1:min(offset + min(limit, PAGE), length(features))]
            links = offset + length(page) < length(features) ?
                [Dict("href" => "$BASE/collections/$name/items?limit=$limit&offset=$(offset + length(page))",
                      "rel" => "next", "type" => "application/geo+json")] : []
            return json(Dict("type" => "FeatureCollection", "features" => page, "links" => links,
                             "numberMatched" => length(features)))
        end
    end
    return notfound
end

HTTP.serve(handle, "127.0.0.1", PORT; verbose=false)
