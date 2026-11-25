"""
    DataEuropa

Julia client for the data.europa.eu open data portal: Search API, Registry (RDF) and SPARQL.

Exports: `search`, `search_datasets`, `iter_datasets`, `fetch_datasets`, `get_dataset`,
`distributions`, `download_distribution`, `load_distribution`, `facet_values`, `count_datasets`, `catalogues`,
`get_rdf`, `sparql`.
"""
module DataEuropa

using HTTP, JSON3, DataFrames, Downloads, CSV, Dates, SHA, MD5

export search, search_datasets, iter_datasets, fetch_datasets, get_dataset, distributions,
       download_distribution, load_distribution, load_geodata, facet_values, count_datasets, catalogues, get_rdf,
       sparql, pick_lang, cache_on, cache_off, clear_cache

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

# ---------------------------------------------------------------- response cache

# Set by cache_on() / cache_off(); `nothing` means "use the environment variable".
const _CACHE = Dict{Symbol,Any}(:on => nothing, :dir => nothing, :ttl => nothing)
const _CACHE_TTL_DEFAULT = 86400  # one day, in seconds

# The operating system's cache folder for dataeuropa.
function _default_cache_dir()
    Sys.iswindows() && return joinpath(get(ENV, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local")),
                                       "dataeuropa", "cache")
    Sys.isapple() && return joinpath(homedir(), "Library", "Caches", "dataeuropa")
    xdg = get(ENV, "XDG_CACHE_HOME", "")
    return joinpath(isempty(xdg) ? joinpath(homedir(), ".cache") : xdg, "dataeuropa")
end

_cache_enabled() = _CACHE[:on] !== nothing ? _CACHE[:on] :
                   lowercase(strip(get(ENV, "DATAEUROPA_CACHE", ""))) in ("1", "true", "yes")

function _cache_dir()
    _CACHE[:dir] !== nothing && return _CACHE[:dir]
    d = get(ENV, "DATAEUROPA_CACHE_DIR", "")
    return isempty(d) ? _default_cache_dir() : d
end

function _cache_ttl()
    _CACHE[:ttl] !== nothing && return Float64(_CACHE[:ttl])
    t = get(ENV, "DATAEUROPA_CACHE_TTL", "")
    return isempty(t) ? Float64(_CACHE_TTL_DEFAULT) : parse(Float64, t)
end

"""
    cache_on(dir=nothing; ttl=nothing) -> String

Turn on the on-disk response cache for this session. Returns the cache folder.

Cached: dataset records ([`get_dataset`](@ref), [`distributions`](@ref)), the catalogue list
([`catalogues`](@ref)), and searches with `limit=0` ([`facet_values`](@ref),
[`count_datasets`](@ref)). Other searches, SPARQL and file downloads are never cached.

`dir` defaults to `DATAEUROPA_CACHE_DIR`, else the operating system's cache folder. `ttl` is how
long a response stays valid, in seconds; it defaults to `DATAEUROPA_CACHE_TTL`, else one day.
The cache is off unless this is called or `DATAEUROPA_CACHE=1` is set.
"""
function cache_on(dir=nothing; ttl=nothing)
    _CACHE[:on] = true
    _CACHE[:dir] = dir === nothing ? nothing : String(dir)
    _CACHE[:ttl] = ttl
    path = _cache_dir()
    mkpath(path)
    return path
end

"""
    cache_off()

Turn off the response cache for this session (cached files stay; see [`clear_cache`](@ref)).
"""
cache_off() = (_CACHE[:on] = false; nothing)

"""
    clear_cache() -> Int

Delete all cached responses. Returns how many were deleted.
"""
function clear_cache()
    path = _cache_dir()
    isdir(path) || return 0
    n = 0
    for name in readdir(path)
        if occursin(r"^[0-9a-f]{64}\.json$", name)
            rm(joinpath(path, name))
            n += 1
        end
    end
    return n
end

# File name of a cached response: SHA-256 of the URL and its sorted query parameters.
function _cache_key(url, query=nothing)
    q = query === nothing ? "" : join(["$k=$(query[k])" for k in sort!(collect(keys(query)); by=string)], "&")
    return bytes2hex(SHA.sha256("$url?$q")) * ".json"
end

# GET a JSON response body, from the cache when it is on, `cacheable` and fresh.
function _get_body(url; query=nothing, cacheable::Bool=false)
    path = cacheable && _cache_enabled() ? joinpath(_cache_dir(), _cache_key(url, query)) : nothing
    ttl = _cache_ttl()   # ttl 0: never fresh, even when the file time is a little ahead of the clock
    if path !== nothing && ttl > 0 && isfile(path) && time() - mtime(path) < ttl
        return read(path)
    end
    body = _request("GET", url; query=query).body
    if path !== nothing
        mkpath(dirname(path))
        tmp = "$path.$(getpid()).tmp"   # write, then rename, so readers never see half a file
        write(tmp, body)
        mv(tmp, path; force=true)
    end
    return body
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

With `limit=0` the result can come from the response cache (see [`cache_on`](@ref)).
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
    # limit=0 (facet counts, hit counts) carries no records, so it may come from the cache.
    return JSON3.read(_get_body("$SEARCH_URL/search"; query=p, cacheable=limit == 0)).result
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
    d = JSON3.read(_get_body("$SEARCH_URL/datasets/$id"; cacheable=true)).result
    raw && return d
    return merge(summarise_dataset(d, lang), (keywords=_keywords(d, lang), raw=d))
end

# Keyword labels in `lang`, plus those with no language tag.
_keywords(d, lang::AbstractString="en") =
    String[string(k.label) for k in something(_get(d, :keywords), []) if _get(k, :language) in (lang, nothing)]

"""
    distributions(id; lang="en", files_only=false) -> DataFrame

Distributions (files, services, pages) of a dataset, one row each. The `url` column is the
download URL if present, otherwise the access URL.

The `kind` column says what each one is: `"file"`, `"service"` (WMS, WFS, APIs, feeds), `"page"`
(a web page), `"none"` (no usable URL, e.g. a localhost placeholder) or `"unknown"`.
`files_only=true` keeps only files.
"""
function distributions(id::AbstractString; lang::AbstractString="en", files_only::Bool=false)
    df = _distribution_table(get_dataset(id; raw=true), lang)
    return files_only && hasproperty(df, :kind) ? df[df.kind .== "file", :] : df
end

# One row per distribution of a raw dataset record; `url` is the download URL, else the access URL.
function _distribution_table(d, lang::AbstractString="en")
    first_or_missing(v) = (v === nothing || isempty(v)) ? missing : String(v[1])
    rows = map(something(_get(d, :distributions), [])) do x
        dl = first_or_missing(_get(x, :download_url)); ac = first_or_missing(_get(x, :access_url))
        cs_algo, cs_value = _checksum(_get(x, :checksum))
        (id = something(_get(x, :id), missing), title = pick_lang(_get(x, :title), lang),
         format = something(_get(_get(x, :format), :id), missing),
         media_type = something(_get(x, :media_type), missing),
         byte_size = something(_get(x, :byte_size), missing),
         checksum = something(cs_value, missing), checksum_algorithm = something(cs_algo, missing),
         license = something(_get(_get(x, :license), :id), missing),
         modified = something(_get(x, :modified), missing),
         download_url = dl, access_url = ac, url = ismissing(dl) ? ac : dl,
         kind = _distribution_kind(_get(_get(x, :format), :id), _get(x, :media_type),
                                   ismissing(dl) ? (ismissing(ac) ? nothing : ac) : dl, ismissing(dl) ? nothing : dl))
    end
    return isempty(rows) ? DataFrame(id=String[], url=String[]) : DataFrame(rows)
end

# Hash algorithms that downloads can be checked with. The portal also has a few others (e.g. CRC).
const _HASHES = Dict("md5" => MD5.md5, "sha1" => SHA.sha1, "sha256" => SHA.sha256)
# Hash lengths in hex digits, for checksums that do not name their algorithm.
const _HASH_BY_LENGTH = Dict(32 => "md5", 40 => "sha1", 64 => "sha256")

# (algorithm, value) of a distribution's `checksum` field, both lowercase, or (nothing, nothing).
# The algorithm is normalised ("SHA-256" and SPDX's "...checksumAlgorithm_sha256" become "sha256").
# When it is not given, a hex value of 32, 40 or 64 digits counts as MD5, SHA-1 or SHA-256;
# otherwise the algorithm is nothing.
function _checksum(cs)
    v = _get(cs, :checksum_value)
    (v isa AbstractString && !isempty(strip(v))) || return (nothing, nothing)
    value = lowercase(strip(String(v)))
    a = _get(cs, :algorithm)
    algo = if a isa AbstractString && !isempty(strip(a))
        key = lowercase(strip(String(a)))
        key = last(split(key, "checksumalgorithm_"))
        replace(key, "-" => "", "_" => "")
    elseif all(c -> c in "0123456789abcdef", value)
        get(_HASH_BY_LENGTH, length(value), nothing)
    else
        nothing
    end
    return (algo, value)
end

# Lowercase hex digest of a file with `algorithm` ("md5", "sha1" or "sha256").
_file_hash(path::AbstractString, algorithm::AbstractString) = open(io -> bytes2hex(_HASHES[algorithm](io)), path)

# Check a downloaded file against its checksum. Returns true if checked, false if there was nothing
# to check with (no checksum, or an algorithm other than MD5, SHA-1, SHA-256). On a mismatch,
# deletes the file and throws an error.
function _verify_checksum(path, algorithm, value)
    (algorithm isa AbstractString && haskey(_HASHES, algorithm) && value isa AbstractString && !isempty(value)) ||
        return false
    got = _file_hash(path, algorithm)
    if got != lowercase(value)
        rm(path; force=true)
        error("checksum mismatch: expected $algorithm $(lowercase(value)), got $got; " *
              "the file was deleted (pass verify=false to keep it)")
    end
    return true
end

# The value to send as If-Range when resuming: a strong ETag, else Last-Modified, else nothing.
# Weak ETags (W/"...") are not allowed in If-Range.
function _range_validator(etag, last_modified)
    etag isa AbstractString && !isempty(strip(etag)) && !startswith(strip(etag), "W/") && return String(strip(etag))
    last_modified isa AbstractString && !isempty(strip(last_modified)) && return String(strip(last_modified))
    return nothing
end

# What to do with the reply to a request for bytes `offset`- of a partial download: "append" (206
# from `offset`), "replace" (200: the whole file, because the server ignores ranges or the file
# changed), "restart" (416, or a 206 for other bytes: start again without a range) or "error".
function _resume_action(status, content_range, offset)
    if status == 206
        m = content_range isa AbstractString ? match(r"^\s*bytes\s+(\d+)-"i, content_range) : nothing
        return m !== nothing && parse(Int, m[1]) == offset ? "append" : "restart"
    end
    status == 200 && return "replace"
    status == 416 && return "restart"
    return "error"
end

_header(resp, name) = (i = findlast(p -> lowercase(p.first) == name, resp.headers); i === nothing ? nothing : resp.headers[i].second)

# Move what arrived for `target` into the partial file `part`, given the reply.
function _settle_piece(target, part, action)
    if action == "append" && target != part
        open(part, "a") do io
            open(src -> write(io, src), target)
        end
        rm(target; force=true)
    elseif target != part
        mv(target, part; force=true)
    end
end

# Download `url` into the partial file `part`, continuing an earlier partial download when
# possible. Downloads.jl only reports the reply after the body, so a resumed body goes to a
# separate file first and is appended or used in place of `part` once the status is known.
# Thrown when a download goes over its size limit (after deleting the partial file).
struct _TooLarge <: Exception
    msg::String
end
_TooLarge(url, max_bytes::Integer) =
    _TooLarge("$url is larger than the limit of $(_thousands(max_bytes)) bytes; the download was stopped")
Base.showerror(io::IO, e::_TooLarge) = print(io, e.msg)
_thousands(n::Integer) = replace(string(n), r"(?<=\d)(?=(\d{3})+$)" => ",")

function _fetch(url, part; resume::Bool, max_bytes::Union{Nothing,Integer}=nothing)
    meta = part * ".json"
    if !startswith(lowercase(url), "http")   # file:// and the like: no ranges
        rm(meta; force=true)
        Downloads.download(url, part; headers=["User-Agent" => UA], timeout=600)
        if max_bytes !== nothing && filesize(part) > max_bytes
            rm(part; force=true)
            throw(_TooLarge(url, max_bytes))
        end
        return
    end
    offset = 0
    hdrs = ["User-Agent" => UA, "Accept-Encoding" => "identity"]   # offsets must refer to the file itself
    if resume && isfile(part) && isfile(meta)
        m = try JSON3.read(read(meta, String)) catch; nothing end
        v = m === nothing ? nothing : _get(m, :validator)
        if m !== nothing && _get(m, :url) == url && v isa AbstractString && filesize(part) > 0
            offset = filesize(part)
            push!(hdrs, "Range" => "bytes=$offset-", "If-Range" => String(v))
        end
    end
    offset == 0 && (rm(part; force=true); rm(meta; force=true))
    target = offset > 0 ? part * ".new" : part
    keep_meta(resp) = (v = _range_validator(_header(resp, "etag"), _header(resp, "last-modified"));
                       v === nothing ? rm(meta; force=true) : write(meta, JSON3.write(Dict("url" => url, "validator" => v))))
    # The size limit: the progress callback sees the announced size (`total`, 0 if unknown) and the
    # bytes received, and interrupts the transfer when either goes over. A resumed part counts too.
    over = Ref(false)
    stop = max_bytes === nothing ? nothing : Base.Event()
    progress = max_bytes === nothing ? nothing : (total, now) -> begin
        if !over[] && offset + max(total, now) > max_bytes
            over[] = true
            notify(stop)
        end
    end
    resp = try
        open(io -> Downloads.request(url; output=io, headers=hdrs, timeout=600, progress=progress, interrupt=stop),
             target, "w")
    catch e
        if over[]
            rm(target; force=true); rm(part; force=true); rm(meta; force=true)
            throw(_TooLarge(url, max_bytes))
        end
        # Interrupted: keep what arrived so the next call can continue from there.
        r = e isa Downloads.RequestError ? e.response : nothing
        if r !== nothing && r.status in (200, 206)
            action = offset > 0 ? _resume_action(r.status, _header(r, "content-range"), offset) : "replace"
            if action in ("append", "replace")
                _settle_piece(target, part, action)
                action == "replace" && keep_meta(r)
            end
        end
        rethrow()
    end
    action = offset > 0 ? _resume_action(resp.status, _header(resp, "content-range"), offset) : "replace"
    if action == "restart"
        rm(target; force=true); rm(part; force=true); rm(meta; force=true)
        return _fetch(url, part; resume=false, max_bytes=max_bytes)
    end
    if action == "error" || resp.status >= 400
        rm(target; force=true)
        offset == 0 && rm(meta; force=true)
        error("HTTP $(resp.status) from $url")
    end
    _settle_piece(target, part, action)
    rm(meta; force=true)
    return
end

"""
    download_distribution(url_or_row, dest="."; verify=true, resume=true, max_bytes=nothing) -> String

Download a distribution (URL string, or a row of [`distributions`](@ref)) to `dest`
(file path or directory). Returns the local path.

If the row has a checksum (`checksum` and `checksum_algorithm`; MD5, SHA-1 or SHA-256), the file
is checked against it. On a mismatch the file is deleted and an error is thrown; `verify=false`
skips the check. `byte_size` is not checked: on the portal it is often a placeholder (0, 1, 1024).

The file is written as `<file>.part` and renamed when complete. If a download is interrupted,
calling `download_distribution` again for the same URL and destination continues where it
stopped, when the server supports ranges and identifies the file (ETag or Last-Modified); a file
that changed meanwhile is downloaded again from the start. `resume=false` always starts from the
start.

`max_bytes` stops a download that is (or is announced as) larger, deletes the partial file and
throws an error. Default: no limit.
"""
function download_distribution(x, dest::AbstractString="."; verify::Bool=true, resume::Bool=true,
                               max_bytes::Union{Nothing,Integer}=nothing)
    url = x isa AbstractString ? String(x) : _field(x, :url)
    (url === nothing || isempty(url)) && throw(ArgumentError("no URL available for this distribution"))
    name = let n = basename(HTTP.URI(url).path); isempty(n) ? "download" : HTTP.URIs.unescapeuri(n) end
    path = isdir(dest) ? joinpath(dest, name) : dest
    _fetch(url, path * ".part"; resume=resume, max_bytes=max_bytes)
    mv(path * ".part", path; force=true)
    if verify && !(x isa AbstractString)
        _verify_checksum(path, _field(x, :checksum_algorithm), _field(x, :checksum))
    end
    return path
end

# ---------------------------------------------------------------- load into a table

# Format ids, media types and file extensions that map to a readable file format.
# Keys are matched after _format_key(): lowercase, look-alike letters folded, leading dot removed.
const _FILE_FORMATS = Dict(
    "csv" => "csv", "text/csv" => "csv", "csv/utf8" => "csv", "comma separated value (csv)" => "csv",
    "tsv" => "csv", "text/tab-separated-values" => "csv",   # the CSV reader detects the tab delimiter
    "json" => "json", "application/json" => "json",
    "xlsx" => "xlsx", "xlsm" => "xlsx", "excel (.xlsx)" => "xlsx",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx",
    "vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx",
    "parquet" => "parquet", "application/vnd.apache.parquet" => "parquet", "application/x-parquet" => "parquet",
)
# Media types and extensions of compressed archives, which must be unpacked before reading.
const _ARCHIVES = Set(["application/zip", "application/x-zip-compressed", "application/gzip",
                       "application/x-gzip", "application/x-tar", "zip", "gz", "tgz", "tar"])
# Format ids of services (map servers, APIs) rather than files. Ids ending in "_srvc" count too.
# Atom and RSS feeds count as services: in INSPIRE they list files rather than being one.
const _SERVICE_FORMATS = Set(["wms", "wfs", "wcs", "wmts", "ogc:wms", "ogc:wfs", "ogc:wcs", "ogc:wmts",
    "ogc:ows-c", "api", "open-api", "ogc api features", "ogcapi-features", "ogcfeat",
    "arcgis geoservices rest api", "rest", "esri rest", "application/vnd.ogc.wms_xml", "sparql", "sparqlq",
    "inspire download service", "atom", "rss", "application/atom+xml", "application/rss+xml"])
# Format ids and media types of web pages (landing pages, links, viewers) rather than files.
const _PAGE_FORMATS = Set(["html", "text/html", "application/xhtml+xml", "web page", "html_simpl", "www:link",
    "www:link-1.0-http--link", "www:link-1.0-http--metadata-url", "url", "view", "doi", "map_prvw"])
# Look-alike letters some publishers type in format ids (Cyrillic а е о р с х, both cases).
const _LOOKALIKES = Dict('а' => 'a', 'е' => 'e', 'о' => 'o', 'р' => 'p', 'с' => 'c', 'х' => 'x',
                         'А' => 'A', 'Е' => 'E', 'О' => 'O', 'Р' => 'P', 'С' => 'C', 'Х' => 'X')
# Format ids that say nothing about the content ("onLine" is ISO 19115 for "a link").
const _NO_FORMAT = Set(["online", "other", "inconnu", "unknown", "n/a"])
# Hosts that only appear in placeholder URLs.
const _PLACEHOLDER_HOSTS = Set(["localhost", "127.0.0.1", "0.0.0.0", "::1", ""])

_str(x) = (x === nothing || x === missing) ? nothing : string(x)
_hastext(x) = x !== nothing && !isempty(strip(x))

# A format id, media type or extension as matched against the tables above.
function _format_key(value)
    key = lowercase(map(c -> get(_LOOKALIKES, c, c), strip(value)))
    startswith(key, "file:///") && (key = String(last(split(key, '/'))))
    return String(lstrip(key, '.'))
end

# The file extension of a URL's last path part, without query or fragment; nothing if none.
function _url_extension(url)
    (url === nothing || isempty(url)) && return nothing
    path = rstrip(first(split(first(split(url, '?'; limit=2)), '#'; limit=2)), '/')
    last_part = last(split(path, '/'))
    return occursin('.', last_part) ? String(last(split(last_part, '.'))) : nothing
end

# "csv", "json", "xlsx", "parquet", "service", "archive", "page" or nothing (unknown). A compressed
# media type or extension means "archive" whatever the format id says; otherwise the first of
# format id, media type, file extension recognised as a service or readable file wins. "page" only
# when one of them says so and none names a service or a file.
function _file_format(fmt=nothing, media_type=nothing, url=nothing)
    fmt, media_type, url = _str(fmt), _str(media_type), _str(url)
    ext = _url_extension(url)
    for cand in (media_type, ext)
        cand !== nothing && _format_key(cand) in _ARCHIVES && return "archive"
    end
    keys = [_format_key(c) for c in (fmt, media_type, ext) if _hastext(c)]
    for key in keys
        (key in _SERVICE_FORMATS || endswith(key, "_srvc")) && return "service"
        haskey(_FILE_FORMATS, key) && return _FILE_FORMATS[key]
    end
    return any(in(_PAGE_FORMATS), keys) ? "page" : nothing
end

# What a distribution is: "file", "service", "page", "none" (no usable URL) or "unknown".
# "none": no URL, a scheme other than http(s) or ftp, or a placeholder host (localhost).
# "service": an OGC query in the URL (service=WMS, request=GetCapabilities), or a service format.
# "page": a web-page format, or no format and an .html URL. "file": any other format or media
# type, or a download URL. Otherwise "unknown". Format ids that say nothing (onLine, OTHER) count
# as no format.
function _distribution_kind(fmt=nothing, media_type=nothing, url=nothing, download_url=nothing)
    fmt, media_type, url, download_url = _str(fmt), _str(media_type), _str(url), _str(download_url)
    _hastext(url) || return "none"
    u = strip(url)
    m = match(r"^([A-Za-z][A-Za-z0-9+.-]*)://(?:[^@/?#]*@)?(\[[^\]]*\]|[^:/?#]*)", u)
    m === nothing && return "none"
    host = lowercase(strip(m[2], ['[', ']']))
    (lowercase(m[1]) in ("http", "https", "ftp") && !(host in _PLACEHOLDER_HOSTS)) || return "none"
    query = occursin('?', u) ? first(split(split(u, '?'; limit=2)[2], '#'; limit=2)) : ""
    occursin(r"(^|&)(service=(wms|wfs|wcs|wmts|csw|wps|sos)|request=getcapabilities)(&|$)"i, query) && return "service"
    f = _file_format(fmt, media_type, url)
    f in ("service", "page") && return f
    (f !== nothing || any(v -> _hastext(v) && !(_format_key(v) in _NO_FORMAT), (fmt, media_type))) && return "file"
    lowercase(something(_url_extension(url), "")) in ("html", "htm") && return "page"
    return _hastext(download_url) ? "file" : "unknown"
end

# Refuse a downloaded file that is an archive or an HTML page rather than data.
function _check_payload(path)
    head = open(io -> read(io, 512), path)
    if (length(head) >= 4 && head[1:4] == UInt8[0x50, 0x4b, 0x03, 0x04]) ||
       (length(head) >= 2 && head[1:2] == UInt8[0x1f, 0x8b])
        throw(ArgumentError("the download is a compressed archive (ZIP or gzip); use download_distribution and unpack it"))
    end
    return _check_html(head)
end

# Refuse a download whose first bytes `head` are an HTML page.
function _check_html(head::Vector{UInt8})
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
instead of data, and formats it cannot tell or read; and an error for files that fail their
checksum (see [`download_distribution`](@ref)).
"""
function load_distribution(x; format=nothing, sheet=nothing)
    url = x isa AbstractString ? String(x) : _field(x, :url)
    (url === nothing || isempty(url)) && throw(ArgumentError("no URL available for this distribution"))
    if format !== nothing
        fmt = _file_format(format)
        fmt in (nothing, "service", "archive", "page") &&
            throw(ArgumentError("format must be one of csv, json, xlsx, parquet (got $(repr(format)))"))
    else
        fmt = x isa AbstractString ? _file_format(nothing, nothing, url) :
              _file_format(_field(x, :format), _field(x, :media_type), url)
    end
    fmt == "service" && throw(ArgumentError("$url is a service, not a file; open it with a client for that service"))
    fmt == "archive" && throw(ArgumentError("$url is a compressed archive; use download_distribution and unpack it"))
    fmt == "page" && throw(ArgumentError("$url is a web page, not a file"))
    fmt === nothing && throw(ArgumentError("cannot tell the file format of $url; pass format=\"csv\", \"json\", \"xlsx\" or \"parquet\""))
    return mktempdir() do tmp
        path = download_distribution(x, joinpath(tmp, "distribution.$fmt"))
        fmt in ("csv", "json") && _check_payload(path)
        _read_table(path, fmt; sheet=sheet)
    end
end

# ---------------------------------------------------------------- geodata

# Format ids, media types and extensions of vector geodata files, after _format_key(). Values are
# the file extension the download is saved under (GDAL needs it for some formats); "zip" for
# formats published as ZIP archives (shapefiles, MapInfo, file geodatabases).
const _GEO_FORMATS = Dict(
    "geojson" => "geojson", "application/geo+json" => "geojson", "geo+json" => "geojson",
    "application/vnd.geo+json" => "geojson",
    "kml" => "kml", "application/vnd.google-earth.kml+xml" => "kml", "vnd.google-earth.kml+xml" => "kml",
    "kmz" => "kmz", "application/vnd.google-earth.kmz" => "kmz", "vnd.google-earth.kmz" => "kmz",
    "gml" => "gml", "application/gml+xml" => "gml", "gml+xml" => "gml", "geographic markup language (gml)" => "gml",
    "xplangml" => "gml", "kuntagml" => "gml",
    "gpkg" => "gpkg", "geopackage" => "gpkg", "geopackage - gpkg" => "gpkg",
    "application/geopackage+sqlite3" => "gpkg", "geopackage+sqlite3" => "gpkg",
    "gpx" => "gpx", "application/gpx+xml" => "gpx", "gpx+xml" => "gpx",
    "fgb" => "fgb", "flatgeobuf" => "fgb",
    "shp" => "zip", "shape" => "zip", "shapefile" => "zip", "shapefiles" => "zip", "shapefile (zip)" => "zip",
    "shapefile zip" => "zip", "shp / zip" => "zip", "esri shape" => "zip", "esri shapefile" => "zip",
    "esri shapefile (shp)" => "zip", "www:download:esri shapefile" => "zip",
    "tab" => "zip", "mapinfo tab" => "zip", "gdb" => "zip", "esri file geodatabase" => "zip",
    "file geodatabase" => "zip",
)
# Extensions of the files GDAL is asked to open inside an archive; a ".gdb" folder counts too.
const _GEO_MEMBER_EXTS = ("shp", "gpkg", "geojson", "kml", "gml", "gpx", "tab", "fgb")
const _NESTED_ARCHIVE_EXTS = ("zip", "kmz", "gz", "tgz", "tar", "7z", "rar")

# The extension to save a geodata download under ("geojson", "kml", "kmz", "gml", "gpkg", "gpx",
# "fgb", or "zip" for shapefiles, MapInfo and file geodatabases), from the format id, then the
# media type, then the URL's extension. `nothing` if none of them names a geodata format.
function _geo_format(fmt=nothing, media_type=nothing, url=nothing)
    for cand in (_str(fmt), _str(media_type), _url_extension(_str(url)))
        (cand === nothing || isempty(strip(cand))) && continue
        key = _format_key(cand)
        haskey(_GEO_FORMATS, key) && return _GEO_FORMATS[key]
    end
    return nothing
end

# The lowercase extension of the last part of a path, "" if none.
function _path_ext(path)
    base = last(split(path, '/'))
    return occursin('.', base) ? lowercase(last(split(base, '.'))) : ""
end

# Choose the file to read inside an archive, from its member `names`. Candidates: files ending in
# .shp, .gpkg, .geojson, .kml, .gml, .gpx, .tab or .fgb, and .gdb folders; macOS metadata is
# ignored. One candidate: that one. Several: the one whose name (without extension) or path equals
# `layer`, ignoring case; `layer` is then used up. Returns (member, layer left for reading).
function _geo_member(names, layer=nothing)
    files = [replace(String(n), '\\' => '/') for n in names if !endswith(n, "/") && !endswith(n, "\\")]
    filter!(n -> !startswith(n, "__MACOSX/") && !startswith(last(split(n, '/')), "._"), files)
    cands = String[]
    for n in files
        m = match(r"\.gdb/"i, n)
        if m !== nothing
            folder = n[1:m.offset+3]
            folder in cands || push!(cands, folder)
        elseif _path_ext(n) in _GEO_MEMBER_EXTS
            push!(cands, n)
        end
    end
    sort!(cands)
    if isempty(cands)
        nested = sort([n for n in files if _path_ext(n) in _NESTED_ARCHIVE_EXTS])
        isempty(nested) || throw(ArgumentError("the archive holds other archives ($(join(nested, ", "))); " *
                                               "download_distribution it and unpack them"))
        throw(ArgumentError("the archive holds no geodata file (looked for .shp, .gpkg, .geojson, .kml, .gml, " *
                            ".gpx, .tab, .fgb files and .gdb folders)"))
    end
    length(cands) == 1 && return (cands[1], layer)
    if layer isa AbstractString
        want = lowercase(layer)
        stem(c) = (b = String(last(split(c, '/'))); lowercase(occursin('.', b) ? b[1:findlast('.', b)-1] : b))
        hits = [c for c in cands if lowercase(c) == want || stem(c) == want]
        length(hits) == 1 && return (hits[1], nothing)
    end
    throw(ArgumentError("the archive holds $(length(cands)) geodata files ($(join(cands, ", "))); pick one with layer="))
end

# The layer to read: `layer` by name (exact, else ignoring case, else once without a namespace
# prefix, as in WFS names: "roads" for "ns:roads") or 1-based position; by default the first,
# with a note if there are more. `what` names the source in messages.
function _pick_layer(layers, layer=nothing, what="the file")
    isempty(layers) && throw(ArgumentError("$what holds no layers"))
    all = join(layers, ", ")
    if layer === nothing
        length(layers) > 1 &&
            @info "$what has $(length(layers)) layers ($all); reading $(repr(first(layers))), pick another with layer="
        return first(layers)
    end
    if layer isa Integer
        1 <= layer <= length(layers) && return layers[layer]
        throw(ArgumentError("layer $layer is out of range: $what has $(length(layers)) layers ($all)"))
    end
    String(layer) in layers && return String(layer)
    want = lowercase(String(layer))
    for hits in ([n for n in layers if lowercase(n) == want],
                 [n for n in layers if last(split(lowercase(n), ':')) == want])   # without a namespace prefix
        length(hits) == 1 && return hits[1]
    end
    throw(ArgumentError("no layer $(repr(String(layer))); $what has $all"))
end

# 2D geometry type names, as GEOS and the Python reference spell them.
const _GEOMETRY_TYPES = Dict(uppercase(t) => t for t in ("Point", "LineString", "Polygon", "MultiPoint",
                                                         "MultiLineString", "MultiPolygon", "GeometryCollection"))

# Defined by the GeoDataFrames package extension: read a local geodata file (or a ZIP holding one),
# or any GDAL data source, into a DataFrame with a `geometry` column; and summarise one for the
# conformance tests.
function _read_geodata end
function _read_source end
function _geo_summary end

# Format ids of the feature services load_geodata reads, after _format_key().
const _WFS_FORMATS = ("wfs", "ogc:wfs", "wfs_srvc")
const _OAPIF_FORMATS = ("ogcfeat", "ogc api features", "ogcapi-features")

# The GDAL data source for a feature service: "WFS:<url>" or "OAPIF:<url>", or `nothing` when the
# distribution is not one (or is another service, such as WMS). A `service=` parameter in the URL
# decides (service=WFS: WFS, anything else: nothing), because format ids are often wrong.
# Otherwise an OGC API Features format id, or a URL ending in /collections/{id} or
# /collections/{id}/items, means OGC API Features (the URL is cut to the collection, without
# query); a WFS format id means WFS. Only http(s) URLs.
function _service_source(fmt=nothing, url=nothing)
    fmt, url = _str(fmt), _str(url)
    (url === nothing || isempty(strip(url))) && return nothing
    u = String(strip(url))
    m = match(r"^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]+)([^?#]*)(\?[^#]*)?", u)
    (m === nothing || !(lowercase(m[1]) in ("http", "https"))) && return nothing
    query = m[4] === nothing ? "" : m[4][2:end]
    path = rstrip(m[3], '/')
    svc = match(r"(?:^|&)service=([^&]*)"i, query)
    svc === nothing || return lowercase(svc[1]) == "wfs" ? "WFS:$u" : nothing
    key = (fmt === nothing || isempty(strip(fmt))) ? "" : _format_key(fmt)
    coll = match(r"/collections/[^/]+(/items)?$", path)
    if key in _OAPIF_FORMATS || coll !== nothing
        coll !== nothing && coll[1] !== nothing && (path = path[1:end-length("/items")])
        return "OAPIF:$(lowercase(m[1]))://$(m[2])$path"
    end
    return key in _WFS_FORMATS ? "WFS:$u" : nothing
end

"""
    load_geodata(url_or_row; layer=nothing, crs=nothing, max_mb=200, max_features=10_000) -> DataFrame

Download a geodata distribution, or read a feature service, into a `DataFrame` with a `geometry` column, as
GeoDataFrames.jl does. Needs `using GeoDataFrames` first. GDAL does the reading, so any vector
format it knows works: GeoJSON, Shapefile, GeoPackage, KML/KMZ, GML, GPX, MapInfo TAB, FlatGeobuf,
file geodatabase. The coordinate reference system is in the table's `"crs"` metadata.

ZIP archives (how shapefiles are published) are opened in place. Inside, the one geodata file is
read (a .shp with its .dbf/.shx/.prj, .gpkg, .geojson, .kml, .gml, .gpx, .tab, .fgb, or a .gdb
folder); if there are several, `layer` picks one by file name (without extension), otherwise an
error lists them. Archives inside archives are not opened.

`layer` picks a layer by name or 1-based position in files with several (GeoPackage, file
geodatabase); by default the first is read, with a note if there are more.

The source coordinate reference system is kept. `crs` (e.g. `"EPSG:4326"`) reprojects; a file
without one (a shapefile without .prj) is read as stored, with a warning.

Files over `max_mb` megabytes (default 200) are not downloaded; `max_mb=nothing` lifts the limit.

Feature services are read too: WFS (`service=WFS` URLs, WFS format ids) and OGC API Features
(collection or landing-page URLs, OGCFEAT format ids). GDAL pages through the results. Each
collection or feature type is a layer. At most `max_features` features (default 10,000) are
read, with a warning when there are more; `max_features=nothing` reads all.

Throws `ArgumentError` for other services (WMS, ...), web pages, HTML served instead of data, and
files or services GDAL cannot read; and an error for checksum mismatches.
"""
function load_geodata(x; layer=nothing, crs=nothing, max_mb::Union{Nothing,Real}=200,
                      max_features::Union{Nothing,Real}=10_000)
    isempty(methods(_read_geodata)) &&
        throw(ArgumentError("load_geodata needs the GeoDataFrames package: `using GeoDataFrames` first"))
    url = x isa AbstractString ? String(x) : _field(x, :url)
    (url === nothing || isempty(url)) && throw(ArgumentError("no URL available for this distribution"))
    fmt, media_type, dl = x isa AbstractString ? (nothing, nothing, nothing) :
                          (_field(x, :format), _field(x, :media_type), _field(x, :download_url))
    source = _service_source(fmt, url)
    if source !== nothing
        limit = max_features === nothing || isinf(max_features) ? nothing : Int(max_features)
        return _read_source(source, layer, crs; max_features=limit, what="the service")
    end
    kind = _distribution_kind(fmt, media_type, url, dl)
    kind == "service" &&
        throw(ArgumentError("$url is a service ($(something(fmt, ""))) that load_geodata cannot read; " *
                            "it reads files, WFS and OGC API Features"))
    kind == "page" && throw(ArgumentError("$url is a web page, not a file"))
    ext = something(_geo_format(fmt, media_type, url), _url_extension(url), "")
    occursin(r"^[A-Za-z0-9]{1,8}$", ext) || (ext = "dat")
    limit = max_mb === nothing || isinf(max_mb) ? nothing : floor(Int, max_mb * 1_000_000)
    return mktempdir() do tmp
        path = try
            download_distribution(x, joinpath(tmp, "distribution.$(lowercase(ext))"); max_bytes=limit)
        catch e
            e isa _TooLarge || rethrow()
            mb = isinteger(max_mb) ? string(Int(max_mb)) : string(max_mb)
            throw(ArgumentError("$url is larger than $mb MB; pass max_mb=nothing to load it anyway"))
        end
        _read_geodata(path, layer, crs)
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
catalogues() = String.(JSON3.read(_get_body("$SEARCH_URL/catalogues"; cacheable=true)))

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
