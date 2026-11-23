"""
    DataEuropa

Julia client for the data.europa.eu open data portal: Search API, Registry (RDF) and SPARQL.

Exports: `search`, `search_datasets`, `iter_datasets`, `fetch_datasets`, `get_dataset`,
`distributions`, `download_distribution`, `load_distribution`, `facet_values`, `count_datasets`, `catalogues`,
`get_rdf`, `sparql`.
"""
module DataEuropa

using HTTP, JSON3, DataFrames, Downloads, CSV, Dates

export search, search_datasets, iter_datasets, fetch_datasets, get_dataset, distributions,
       download_distribution, load_distribution, facet_values, count_datasets, catalogues, get_rdf,
       sparql, pick_lang

const SEARCH_URL = "https://data.europa.eu/api/hub/search"
const REPO_URL = "https://data.europa.eu/api/hub/repo"
const SPARQL_URL = "https://data.europa.eu/sparql"
const UA = "DataEuropa.jl/0.1 (+https://data.europa.eu)"

const FACET_ALIASES = Dict(
    :country => "country", :catalog => "catalog", :catalogue => "catalog", :format => "format",
    :license => "license", :licence => "license", :category => "categories",
    :categories => "categories", :publisher => "publisher", :keyword => "keywords",
    :keywords => "keywords", :hvd => "is_hvd", :source_type => "source_type",
    :super_catalog => "superCatalog",
)

timeout() = parse(Int, get(ENV, "DATAEUROPA_TIMEOUT", "60"))

# ---------------------------------------------------------------- helpers

"""
    pick_lang(x, lang="en")

Collapse a `{lang: text}` object to one string (requested language, then English, then any).
"""
function pick_lang(x, lang::AbstractString="en")
    x === nothing && return missing
    x isa AbstractString && return String(x)
    if x isa JSON3.Array
        return isempty(x) ? missing : pick_lang(x[1], lang)
    end
    if x isa JSON3.Object || x isa AbstractDict
        for k in (Symbol(lang), :en)
            haskey(x, k) && !isempty(string(x[k])) && return string(x[k])
        end
        for (_, v) in pairs(x)
            v isa AbstractString && !isempty(v) && return String(v)
        end
    end
    return missing
end

_get(x, k, default=nothing) = (x !== nothing && x isa Union{JSON3.Object,AbstractDict} && haskey(x, k)) ? x[k] : default

function _request(method, url; query=nothing, body=nothing, headers=Pair{String,String}[])
    hdrs = ["User-Agent" => UA; headers]
    local resp
    for attempt in 1:4
        resp = HTTP.request(method, url, hdrs, body === nothing ? UInt8[] : body;
                            query=query, status_exception=false, readtimeout=timeout(),
                            connect_timeout=30, redirect=true)
        resp.status in (429, 500, 502, 503, 504) || break
        sleep(0.8 * 2^(attempt - 1))
    end
    if resp.status >= 400
        msg = try
            String(JSON3.read(resp.body).message)
        catch
            first(String(copy(resp.body)), 300)
        end
        error("HTTP $(resp.status) from $url: $msg")
    end
    return resp
end

function _facets(facets, named)
    out = Dict{String,Vector{String}}()
    if facets !== nothing
        for (k, v) in pairs(facets)
            out[string(k)] = v isa AbstractString ? [String(v)] : String.(collect(v))
        end
    end
    for (k, v) in pairs(named)
        v === nothing && continue
        fid = FACET_ALIASES[k]
        conv(s) = fid == "country" ? lowercase(string(s)) : string(s)
        vals = v isa Bool ? [v ? "true" : "false"] :
               v isa AbstractString ? [conv(v)] : [conv(s) for s in v]
        append!(get!(out, fid, String[]), vals)
    end
    return isempty(out) ? nothing : out
end

# ---------------------------------------------------------------- search

# Check (min_lon, min_lat, max_lon, max_lat) and return the Search API parameters. The API ignores
# an incomplete box and rejects min > max with an unhelpful 400, so check here.
function _bbox_params(bbox)
    msg = "bbox must be 4 numbers: (min_lon, min_lat, max_lon, max_lat)"
    (bbox isa Union{Tuple,AbstractVector} && length(bbox) == 4 && all(v -> v isa Real, bbox)) ||
        throw(ArgumentError(msg))
    min_lon, min_lat, max_lon, max_lat = Float64.(collect(bbox))
    -180 <= min_lon <= max_lon <= 180 ||
        throw(ArgumentError("bbox longitudes must satisfy -180 <= min_lon <= max_lon <= 180"))
    -90 <= min_lat <= max_lat <= 90 ||
        throw(ArgumentError("bbox latitudes must satisfy -90 <= min_lat <= max_lat <= 90"))
    return Dict{String,Any}("bboxMinLon" => min_lon, "bboxMinLat" => min_lat,
                            "bboxMaxLon" => max_lon, "bboxMaxLat" => max_lat)
end

"""
    search(q=nothing; filters="dataset", facets=nothing, limit=10, page=0, sort=nothing,
           country, catalog, format, license, category, publisher, keywords, hvd,
           min_date, max_date, date_type, bbox, aggregation=false, extra=Dict())

Raw Search API call; returns the `result` object (`count`, `results`, `facets`, ...).
`country` takes ISO-2 codes ("pt"), `format` ids such as "CSV", `category` DCAT-AP theme codes
("ENVI"). Use [`facet_values`](@ref) to discover ids. `sort` e.g. "modified+desc".

`bbox` is `(min_lon, min_lat, max_lon, max_lat)` in WGS84 degrees. A dataset matches when its
spatial extent overlaps the box, so datasets covering all of Europe or the world match any box.
Datasets without a spatial extent (about half the portal) never match.
"""
function search(q::Union{Nothing,AbstractString}=nothing; filters="dataset", facets=nothing,
                limit::Integer=10, page::Integer=0, sort=nothing, country=nothing, catalog=nothing,
                format=nothing, license=nothing, category=nothing, publisher=nothing,
                keywords=nothing, hvd=nothing, min_date=nothing, max_date=nothing,
                date_type=nothing, bbox=nothing, aggregation::Bool=false, extra=Dict{String,Any}())
    p = Dict{String,Any}("limit" => limit, "page" => page, "aggregation" => aggregation)
    q !== nothing && !isempty(q) && (p["q"] = q)
    filters !== nothing && (p["filters"] = filters isa AbstractString ? filters : join(filters, ","))
    fac = _facets(facets, (country=country, catalog=catalog, format=format, license=license,
                           category=category, publisher=publisher, keywords=keywords, hvd=hvd))
    fac !== nothing && (p["facets"] = JSON3.write(fac))
    sort !== nothing && (p["sort"] = sort isa AbstractString ? sort : join(sort, ","))
    min_date !== nothing && (p["minDate"] = min_date)
    max_date !== nothing && (p["maxDate"] = max_date)
    date_type !== nothing && (p["dateType"] = date_type)
    bbox !== nothing && merge!(p, _bbox_params(bbox))
    for (k, v) in pairs(extra)
        p[string(k)] = v
    end
    resp = _request("GET", "$SEARCH_URL/search"; query=p)
    return JSON3.read(resp.body).result
end

"""
    summarise_dataset(d, lang="en") -> NamedTuple

Flatten one raw dataset record to the commonly needed fields.
"""
function summarise_dataset(d, lang::AbstractString="en")
    dists = _get(d, :distributions, [])
    fmts = sort!(unique(String[string(f) for x in dists for f in (_get(_get(x, :format), :id),) if f !== nothing]))
    lp = _get(d, :landing_page, [])
    id = _get(d, :id)
    return (
        id = id === nothing ? missing : String(id),
        title = pick_lang(_get(d, :title), lang),
        description = pick_lang(_get(d, :description), lang),
        country = something(_get(_get(d, :country), :id), missing),
        catalog = something(_get(_get(d, :catalog), :id), missing),
        publisher = something(_get(_get(d, :publisher), :name), missing),
        issued = something(_get(d, :issued), missing),
        modified = something(_get(d, :modified), missing),
        formats = fmts,
        n_distributions = length(dists),
        is_hvd = something(_get(d, :is_hvd), missing),
        quality_score = something(_get(_get(d, :quality_meas), :scoring), missing),
        landing_page = isempty(lp) ? missing : something(_get(lp[1], :resource), missing),
        portal_url = "https://data.europa.eu/data/datasets/$(id)",
    )
end

"""
    search_datasets(q=nothing; lang="en", kwargs...) -> DataFrame

Search datasets and return a `DataFrame` (total hits in `metadata(df, "count")`).
Accepts every keyword of [`search`](@ref).
"""
function search_datasets(q::Union{Nothing,AbstractString}=nothing; lang::AbstractString="en", kwargs...)
    res = search(q; kwargs...)
    df = DataFrame([summarise_dataset(d, lang) for d in res.results])
    isempty(df) && (df = DataFrame(id=String[], title=String[]))
    metadata!(df, "count", Int(res.count); style=:note)
    return df
end

"""
    iter_datasets(q=nothing; max_results=nothing, page_size=500, kwargs...) -> Channel

Lazily iterate *raw* dataset records of a large result set using the scroll API.
"""
function iter_datasets(q::Union{Nothing,AbstractString}=nothing; max_results=nothing,
                       page_size::Integer=500, kwargs...)
    kw = Dict{Symbol,Any}(kwargs)
    delete!(kw, :limit); delete!(kw, :page)
    extra = Dict{String,Any}(string(k) => v for (k, v) in pairs(get(kw, :extra, Dict())))
    extra["scroll"] = true
    kw[:extra] = extra
    return Channel{Any}(1) do ch
        res = search(q; limit=min(page_size, 1000), kw...)
        n = 0
        while true
            for d in res.results
                put!(ch, d)
                n += 1
                max_results !== nothing && n >= max_results && return
            end
            sid = _get(res, :scrollId)
            (isempty(res.results) || sid === nothing) && return
            resp = _request("GET", "$SEARCH_URL/scroll"; query=Dict("scrollId" => sid))
            res = JSON3.read(resp.body).result
        end
    end
end

"""
    fetch_datasets(q=nothing; max_results=1000, lang="en", kwargs...) -> DataFrame

Collect up to `max_results` datasets (scroll) into a `DataFrame`.
"""
function fetch_datasets(q::Union{Nothing,AbstractString}=nothing; max_results::Integer=1000,
                        lang::AbstractString="en", kwargs...)
    rows = [summarise_dataset(d, lang) for d in iter_datasets(q; max_results=max_results, kwargs...)]
    return isempty(rows) ? DataFrame(id=String[], title=String[]) : DataFrame(rows)
end

"""
    get_dataset(id; raw=false, lang="en")

Full metadata for one dataset. With `raw=true` returns the untouched JSON object; otherwise a
`NamedTuple` summary with an extra `keywords` and `raw` field.
"""
function get_dataset(id::AbstractString; raw::Bool=false, lang::AbstractString="en")
    d = JSON3.read(_request("GET", "$SEARCH_URL/datasets/$id").body).result
    raw && return d
    return merge(summarise_dataset(d, lang), (keywords=_keywords(d, lang), raw=d))
end

# Keyword labels in `lang`, plus those with no language tag.
_keywords(d, lang::AbstractString="en") =
    String[string(k.label) for k in something(_get(d, :keywords), []) if _get(k, :language) in (lang, nothing)]

"""
    distributions(id; lang="en") -> DataFrame

Distributions (files / services) of a dataset. The `url` column is the download URL if
present, otherwise the access URL.
"""
distributions(id::AbstractString; lang::AbstractString="en") = _distribution_table(get_dataset(id; raw=true), lang)

# One row per distribution of a raw dataset record; `url` is the download URL, else the access URL.
function _distribution_table(d, lang::AbstractString="en")
    first_or_missing(v) = (v === nothing || isempty(v)) ? missing : String(v[1])
    rows = map(something(_get(d, :distributions), [])) do x
        dl = first_or_missing(_get(x, :download_url)); ac = first_or_missing(_get(x, :access_url))
        (id = something(_get(x, :id), missing), title = pick_lang(_get(x, :title), lang),
         format = something(_get(_get(x, :format), :id), missing),
         media_type = something(_get(x, :media_type), missing),
         byte_size = something(_get(x, :byte_size), missing),
         license = something(_get(_get(x, :license), :id), missing),
         modified = something(_get(x, :modified), missing),
         download_url = dl, access_url = ac, url = ismissing(dl) ? ac : dl)
    end
    return isempty(rows) ? DataFrame(id=String[], url=String[]) : DataFrame(rows)
end

"""
    download_distribution(url_or_row, dest=".") -> String

Download a distribution (URL string, or a row of [`distributions`](@ref)) to `dest`
(file path or directory). Returns the local path.
"""
function download_distribution(x, dest::AbstractString=".")
    url = x isa AbstractString ? String(x) : String(x.url)
    name = let n = basename(HTTP.URI(url).path); isempty(n) ? "download" : HTTP.URIs.unescapeuri(n) end
    path = isdir(dest) ? joinpath(dest, name) : dest
    Downloads.download(url, path; headers=["User-Agent" => UA], timeout=600)
    return path
end

# ---------------------------------------------------------------- load into a table

# Format ids, media types and file extensions that map to a readable file format.
const _FILE_FORMATS = Dict(
    "csv" => "csv", "text/csv" => "csv", "csv/utf8" => "csv", "comma separated value (csv)" => "csv",
    "json" => "json", "application/json" => "json",
    "xlsx" => "xlsx", "xlsm" => "xlsx",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx",
    "parquet" => "parquet", "application/vnd.apache.parquet" => "parquet", "application/x-parquet" => "parquet",
)
# Media types and extensions of compressed archives, which must be unpacked before reading.
const _ARCHIVES = Set(["application/zip", "application/x-zip-compressed", "application/gzip",
                       "application/x-gzip", "application/x-tar", "zip", "gz", "tgz", "tar"])
# Format ids of services (map servers, APIs) rather than files. Ids ending in "_srvc" count too.
const _SERVICE_FORMATS = Set(["wms", "wfs", "wcs", "wmts", "ogc:wms", "ogc:wfs", "api", "open-api",
    "ogc api features", "ogcapi-features", "arcgis geoservices rest api", "application/vnd.ogc.wms_xml", "sparql"])

_str(x) = (x === nothing || x === missing) ? nothing : string(x)

# "csv", "json", "xlsx", "parquet", "service", "archive" or nothing (unknown). A compressed media
# type or extension means "archive" whatever the format id says; otherwise the first recognised
# of format id, media type, file extension wins.
function _file_format(fmt=nothing, media_type=nothing, url=nothing)
    fmt, media_type, url = _str(fmt), _str(media_type), _str(url)
    ext = nothing
    if url !== nothing && !isempty(url)
        path = rstrip(first(split(first(split(url, '?'; limit=2)), '#'; limit=2)), '/')
        last_part = last(split(path, '/'))
        ext = occursin('.', last_part) ? String(last(split(last_part, '.'))) : nothing
    end
    for cand in (media_type, ext)
        cand !== nothing && lowercase(strip(cand)) in _ARCHIVES && return "archive"
    end
    for cand in (fmt, media_type, ext)
        (cand === nothing || isempty(strip(cand))) && continue
        key = lowercase(strip(cand))
        startswith(key, "file:///") && (key = String(last(split(key, '/'))))
        (key in _SERVICE_FORMATS || endswith(key, "_srvc")) && return "service"
        haskey(_FILE_FORMATS, key) && return _FILE_FORMATS[key]
    end
    return nothing
end

# Refuse a downloaded file that is an archive or an HTML page rather than data.
function _check_payload(path)
    head = open(io -> read(io, 512), path)
    if (length(head) >= 4 && head[1:4] == UInt8[0x50, 0x4b, 0x03, 0x04]) ||
       (length(head) >= 2 && head[1:2] == UInt8[0x1f, 0x8b])
        throw(ArgumentError("the download is a compressed archive (ZIP or gzip); use download_distribution and unpack it"))
    end
    start = lowercase(lstrip(String(Char.(head)), ['﻿', 'ï', '»', '¿', ' ', '\t', '\r', '\n']))
    (startswith(start, "<!doctype html") || startswith(start, "<html")) &&
        throw(ArgumentError("the download is an HTML page, not a data file (often a landing page)"))
    return nothing
end

# UTF-8 (with or without a byte-order mark), falling back to Latin-1.
function _decode(raw::Vector{UInt8})
    length(raw) >= 3 && raw[1:3] == UInt8[0xef, 0xbb, 0xbf] && (raw = raw[4:end])
    return isvalid(String, raw) ? String(copy(raw)) : String(Char.(raw))
end

# The most frequent of , ; tab | in the header line (comma on a tie or if none occurs).
function _sniff_delimiter(text::AbstractString)
    header = first(split(text, '\n'; limit=2))
    counts = Dict(d => count(==(d), header) for d in (',', ';', '\t', '|'))
    best = maximum(values(counts))
    (best == 0 || counts[','] == best) && return ','
    return first(d for d in (';', '\t', '|') if counts[d] == best)
end

# An array of objects, or an object holding exactly one array of objects.
function _json_records(data)
    isobj(r) = r isa JSON3.Object
    data isa JSON3.Array && all(isobj, data) && return collect(data)
    if data isa JSON3.Object
        lists = [v for (_, v) in pairs(data) if v isa JSON3.Array && !isempty(v) && all(isobj, v)]
        length(lists) == 1 && return collect(lists[1])
    end
    throw(ArgumentError("JSON is not a table: expected an array of objects, or an object holding one"))
end

_plain(x) = x === nothing ? missing : x isa AbstractString ? String(x) : x

# Defined by the XLSX and Parquet2 package extensions.
function _read_xlsx end
function _read_parquet end

# Read a local file of format `fmt` into a DataFrame.
function _read_table(path, fmt::AbstractString; sheet=nothing)
    if fmt == "csv"
        text = _decode(read(path))
        return CSV.read(IOBuffer(text), DataFrame; delim=_sniff_delimiter(text), missingstring="",
                        stringtype=String, typemap=IdDict(Dates.Date => String, Dates.DateTime => String,
                                                          Dates.Time => String))
    elseif fmt == "json"
        records = _json_records(JSON3.read(_decode(read(path))))
        cols = Symbol[]
        for r in records, k in keys(r)
            k in cols || push!(cols, k)
        end
        df = DataFrame()
        for c in cols
            vals = Any[_plain(get(r, c, nothing)) for r in records]
            isnum(v) = v === missing || (v isa Real && !(v isa Bool))
            if all(isnum, vals) && any(v -> v isa AbstractFloat, vals)
                vals = Any[v === missing ? missing : Float64(v) for v in vals]  # mixed numbers -> Float64
            end
            df[!, String(c)] = identity.(vals)
        end
        return df
    elseif fmt == "xlsx"
        isempty(methods(_read_xlsx)) && throw(ArgumentError("reading XLSX needs the XLSX package: `using XLSX` first"))
        return _read_xlsx(path, sheet)
    elseif fmt == "parquet"
        isempty(methods(_read_parquet)) && throw(ArgumentError("reading Parquet needs the Parquet2 package: `using Parquet2` first"))
        return _read_parquet(path)
    end
    throw(ArgumentError("unsupported format $(repr(fmt))"))
end

_field(x, k) = (x isa NamedTuple || x isa DataFrameRow || x isa AbstractDict) ?
    _str(x isa AbstractDict ? get(x, k, get(x, string(k), nothing)) : (hasproperty(x, k) ? getproperty(x, k) : nothing)) :
    nothing

"""
    load_distribution(url_or_row; format=nothing, sheet=nothing) -> DataFrame

Download a distribution and read it into a `DataFrame`. Accepts a URL, or a row of
[`distributions`](@ref). Reads CSV and JSON; XLSX after `using XLSX`, Parquet after
`using Parquet2`. The format comes from `format` if given (`"csv"`, `"json"`, `"xlsx"`,
`"parquet"`), else from the row's format id, its media type, then the URL's file extension.
`sheet` picks an XLSX sheet by name or 1-based index (default: the first).

CSV: the delimiter (`,` `;` tab `|`) is taken from the header line, text is read as UTF-8 with a
Latin-1 fallback, only empty cells count as missing, and dates stay text. JSON: an array of
objects, or an object holding exactly one such array; keys become columns.

Throws `ArgumentError` for services (WMS, WFS, APIs), compressed archives, HTML pages served
instead of data, and formats it cannot tell or read.
"""
function load_distribution(x; format=nothing, sheet=nothing)
    url = x isa AbstractString ? String(x) : _field(x, :url)
    (url === nothing || isempty(url)) && throw(ArgumentError("no URL available for this distribution"))
    if format !== nothing
        fmt = _file_format(format)
        fmt in (nothing, "service", "archive") &&
            throw(ArgumentError("format must be one of csv, json, xlsx, parquet (got $(repr(format)))"))
    else
        fmt = x isa AbstractString ? _file_format(nothing, nothing, url) :
              _file_format(_field(x, :format), _field(x, :media_type), url)
    end
    fmt == "service" && throw(ArgumentError("$url is a service, not a file; open it with a client for that service"))
    fmt == "archive" && throw(ArgumentError("$url is a compressed archive; use download_distribution and unpack it"))
    fmt === nothing && throw(ArgumentError("cannot tell the file format of $url; pass format=\"csv\", \"json\", \"xlsx\" or \"parquet\""))
    return mktempdir() do tmp
        path = download_distribution(url, joinpath(tmp, "distribution.$fmt"))
        fmt in ("csv", "json") && _check_payload(path)
        _read_table(path, fmt; sheet=sheet)
    end
end

"""
    facet_values(facet, q=nothing; top=50, kwargs...) -> DataFrame

Values and counts of a facet (`"country"`, `"format"`, `"categories"`, `"catalog"`, ...).
"""
function facet_values(facet::AbstractString, q::Union{Nothing,AbstractString}=nothing;
                      top::Union{Nothing,Integer}=50, filters="dataset", kwargs...)
    fid = get(FACET_ALIASES, Symbol(facet), facet)
    extra = Dict{String,Any}("aggregationAllFields" => false, "aggregationFields" => fid)
    res = search(q; filters=filters, limit=0, aggregation=true, extra=extra, kwargs...)
    df = _facet_table(res, fid, top)
    df === nothing && error("unknown facet $(repr(facet))")
    return df
end

# Rows (id, label, count) of facet `fid` in a search result, most frequent first; `nothing` if
# absent. `label` is the item's title, else its label, else its id; a missing count is 0.
# Ties keep the API's order.
function _facet_table(res, fid::AbstractString, top=nothing)
    for f in something(_get(res, :facets), [])
        if _get(f, :id) == fid
            rows = map(something(_get(f, :items), [])) do i
                id = String(i.id)
                label = coalesce(pick_lang(_get(i, :title)), _nonempty(_get(i, :label)), id)
                (id = id, label = label, count = Int(something(_get(i, :count), 0)))
            end
            df = isempty(rows) ? DataFrame(id=String[], label=String[], count=Int[]) : DataFrame(rows)
            sort!(df, :count; rev=true, alg=MergeSort)
            return top === nothing ? df : first(df, top)
        end
    end
    return nothing
end

_nonempty(x) = (x === nothing || isempty(string(x))) ? missing : string(x)

"""
    count_datasets(q=nothing; kwargs...) -> Int

Number of hits for a query, without transferring records.
"""
count_datasets(q::Union{Nothing,AbstractString}=nothing; kwargs...) = Int(search(q; limit=0, kwargs...).count)

"""
    catalogues() -> Vector{String}

Ids of all harvested catalogues.
"""
catalogues() = String.(JSON3.read(_request("GET", "$SEARCH_URL/catalogues").body))

"""
    get_rdf(id, fmt="ttl") -> String

Dataset metadata as RDF text from the Registry API (`"ttl"` Turtle or `"jsonld"`).
"""
function get_rdf(id::AbstractString, fmt::AbstractString="ttl")
    fmt in ("ttl", "jsonld") || throw(ArgumentError("fmt must be \"ttl\" or \"jsonld\""))
    return String(_request("GET", "$REPO_URL/datasets/$id.$fmt").body)
end

"""
    sparql(query) -> DataFrame | Bool

Run a SPARQL SELECT (returns a `DataFrame` of plain string values) or ASK (returns `Bool`).
"""
function sparql(query::AbstractString)
    resp = _request("POST", SPARQL_URL; body=HTTP.escapeuri(Dict("query" => query)),
                    headers=["Content-Type" => "application/x-www-form-urlencoded",
                             "Accept" => "application/sparql-results+json"])
    return _sparql_result(JSON3.read(resp.body))
end

# ASK result as a Bool, or SELECT bindings as a DataFrame of plain strings (missing when unbound).
function _sparql_result(j)
    haskey(j, :boolean) && return Bool(j.boolean)
    cols = String.(j.head.vars)
    rows = [Dict(c => (haskey(b, Symbol(c)) ? String(b[Symbol(c)].value) : missing) for c in cols)
            for b in j.results.bindings]
    return DataFrame([c => [get(r, c, missing) for r in rows] for c in cols])
end

end # module
