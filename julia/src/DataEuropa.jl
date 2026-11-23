"""
    DataEuropa

Julia client for the data.europa.eu open data portal: Search API, Registry (RDF) and SPARQL.

Exports: `search`, `search_datasets`, `iter_datasets`, `fetch_datasets`, `get_dataset`,
`distributions`, `download_distribution`, `facet_values`, `count_datasets`, `catalogues`,
`get_rdf`, `sparql`.
"""
module DataEuropa

using HTTP, JSON3, DataFrames, Downloads

export search, search_datasets, iter_datasets, fetch_datasets, get_dataset, distributions,
       download_distribution, facet_values, count_datasets, catalogues, get_rdf, sparql, pick_lang

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
