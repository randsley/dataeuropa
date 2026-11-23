module DataEuropaGeoDataFramesExt

using DataEuropa, DataFrames, GeoDataFrames

const AG = GeoDataFrames.AG
const GI = GeoDataFrames.GeoInterface
const GFT = GeoDataFrames.GFT

# Layer names, and each layer's FID column when it is not also a field ("fid" in GeoPackages;
# GeoJSON reports an "id" property as FID column but it stays a field). "" if none.
function _layers(src)
    return AG.read(src) do ds
        map(0:AG.nlayer(ds)-1) do i
            layer = AG.getlayer(ds, i)
            fid = AG.GDAL.ogr_l_getfidcolumn(layer.ptr)
            defn = AG.layerdefn(layer)
            fields = [AG.getname(AG.getfielddefn(defn, j)) for j in 0:AG.nfield(defn)-1]
            (AG.getname(layer), fid in fields ? "" : fid)
        end
    end
end

# A target coordinate reference system as GeoDataFrames.reproject takes it: "EPSG:n" or an
# integer as an EPSG code; any other text (PROJ string, WKT, "WGS84") as GDAL understands it.
_target_crs(crs::GFT.GeoFormat) = crs
_target_crs(crs::Integer) = GFT.EPSG(crs)
function _target_crs(crs::AbstractString)
    m = match(r"^\s*EPSG:(\d+)\s*$"i, crs)
    m === nothing || return GFT.EPSG(parse(Int, m[1]))
    return GFT.WellKnownText(GFT.CRS(), AG.toWKT(AG.importUserInput(String(crs))))
end

function DataEuropa._read_geodata(path, layer, crs)
    head = open(io -> read(io, 512), path)
    DataEuropa._check_html(head)
    src = replace(abspath(path), '\\' => '/')
    if length(head) >= 4 && head[1:4] == UInt8[0x50, 0x4b, 0x03, 0x04]
        member, layer = DataEuropa._geo_member(something(AG.GDAL.vsireaddirrecursive("/vsizip/$src"), String[]), layer)
        src = "/vsizip/$src/$member"
    elseif length(head) >= 2 && head[1:2] == UInt8[0x1f, 0x8b]
        src = "/vsigzip/$src"
    end
    return DataEuropa._read_source(src, layer, crs)
end

# GeoDataFrames warns "Ignoring key-value metadata string" for metadata it cannot parse, such as
# the JSON description of every OGC API collection. Pass every other log record on.
const CL = Base.CoreLogging
struct _QuietMetadata{L<:CL.AbstractLogger} <: CL.AbstractLogger
    parent::L
end
CL.min_enabled_level(l::_QuietMetadata) = CL.min_enabled_level(l.parent)
CL.shouldlog(l::_QuietMetadata, args...) = CL.shouldlog(l.parent, args...)
CL.catch_exceptions(l::_QuietMetadata) = CL.catch_exceptions(l.parent)
function CL.handle_message(l::_QuietMetadata, level, msg, args...; kwargs...)
    msg isa AbstractString && startswith(msg, "Ignoring key-value metadata") && return nothing
    return CL.handle_message(l.parent, level, msg, args...; kwargs...)
end

# Run an OGR SQL query on a data source into a DataFrame shaped as GeoDataFrames.read makes them
# (geometry column `geometry`, "crs" and "geometrycolumns" metadata). Used for feature limits.
function _read_sql(src, sql)
    df, crs = AG.read(src) do ds
        AG.executesql(ds, sql) do t
            sr = AG.getspatialref(t)
            DataFrame(t), (sr.ptr == C_NULL ? nothing : GFT.WellKnownText(GFT.CRS(), AG.toWKT(sr)))
        end
    end
    g = findfirst(n -> nonmissingtype(eltype(df[!, n])) <: AG.AbstractGeometry, names(df))
    g === nothing && return df
    g == "geometry" || rename!(df, g => "geometry")
    for (key, value) in ("crs" => crs, "geometrycolumns" => (:geometry,),
                         "GEOINTERFACE:crs" => crs, "GEOINTERFACE:geometrycolumns" => (:geometry,))
        metadata!(df, key, value; style=:note)
    end
    return df
end

# Read a GDAL data source (a local path, /vsizip/ path, or WFS:/OAPIF: service) into a DataFrame.
# `max_features`: read at most that many (with OGR SQL LIMIT), with a warning if there are more.
function DataEuropa._read_source(src, layer=nothing, crs=nothing; max_features=nothing, what="the file")
    layers = try
        _layers(src)
    catch e
        throw(ArgumentError("cannot read $what as geodata: $(sprint(showerror, e))"))
    end
    name = DataEuropa._pick_layer(first.(layers), layer)
    fid = last(layers[findfirst(l -> first(l) == name, layers)])
    df = try
        if max_features === nothing
            CL.with_logger(_QuietMetadata(CL.current_logger())) do
                GeoDataFrames.read(GeoDataFrames.ArchGDALDriver(), src; layer=name)
            end
        else
            _read_sql(src, "SELECT * FROM \"$(replace(name, "\"" => "\"\""))\" LIMIT $(max_features + 1)")
        end
    catch e
        what == "the file" && rethrow()
        throw(ArgumentError("cannot read $what: $(sprint(showerror, e))"))
    end
    if max_features !== nothing && nrow(df) > max_features
        n = DataEuropa._thousands(max_features)
        @warn "$what has more than $n features; read the first $n (pass max_features=nothing for all)"
        deleteat!(df, max_features+1:nrow(df))
    end
    gcols = metadata(df, "geometrycolumns", ())
    (isempty(gcols) || !(String(first(gcols)) in names(df))) &&
        throw(ArgumentError("$what has no geometries (a plain table?); use load_distribution"))
    # Like Python and R: the FID column is not an attribute, and the geometry column is `geometry`.
    !isempty(fid) && fid in names(df) && select!(df, Not(fid))
    if first(gcols) != :geometry
        rename!(df, first(gcols) => :geometry)
        for key in ("geometrycolumns", "GEOINTERFACE:geometrycolumns")
            key in metadatakeys(df) && metadata!(df, key, (:geometry,); style=:note)
        end
    end
    if metadata(df, "crs", nothing) === nothing
        crs === nothing || throw(ArgumentError("the data has no coordinate reference system (no .prj file?), so it " *
                                               "cannot be reprojected; read it without crs and set the \"crs\" metadata"))
        @warn "the data has no coordinate reference system (no .prj file?); coordinates are as stored"
    elseif crs !== nothing
        df = GeoDataFrames.reproject(df, _target_crs(crs))
    end
    return df
end

# The EPSG code of a coordinate reference system, or `nothing`.
function _epsg(crs)
    crs === nothing && return nothing
    code = AG.importCRS(crs) do sr
        AG.GDAL.osrautoidentifyepsg(sr.ptr)
        AG.GDAL.osrgetauthoritycode(sr.ptr, C_NULL)
    end
    return code === nothing ? nothing : tryparse(Int, code)
end

function DataEuropa._geo_summary(df, columns=nothing)
    attrs = [n for n in names(df) if n != "geometry"]
    cols = columns === nothing ? attrs : String.(collect(columns))
    out = Dict{String,Any}()
    columns === nothing && (out["columns"] = attrs)
    out["values"] = Dict(c => [v === missing ? nothing : v for v in df[!, c]] for c in cols)
    out["nrow"] = nrow(df)
    types = Set{String}()
    xmin, ymin, xmax, ymax = Inf, Inf, -Inf, -Inf
    for g in df.geometry
        name = replace(string(nameof(typeof(GI.geomtrait(g)))), "Trait" => "")
        push!(types, get(DataEuropa._GEOMETRY_TYPES, uppercase(name), name))
        e = GI.extent(g)
        xmin, xmax = min(xmin, e.X[1]), max(xmax, e.X[2])
        ymin, ymax = min(ymin, e.Y[1]), max(ymax, e.Y[2])
    end
    out["geometry_types"] = sort(collect(types))
    out["crs"] = _epsg(metadata(df, "crs", nothing))
    out["bounds"] = round.([xmin, ymin, xmax, ymax]; digits=6)
    return out
end

end
