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
    layers = try
        _layers(src)
    catch e
        throw(ArgumentError("cannot read the file as geodata: $(sprint(showerror, e))"))
    end
    name = DataEuropa._pick_layer(first.(layers), layer)
    fid = last(layers[findfirst(l -> first(l) == name, layers)])
    df = GeoDataFrames.read(GeoDataFrames.ArchGDALDriver(), src; layer=name)
    gcols = GeoDataFrames.getgeometrycolumns(df)
    (isempty(gcols) || !(String(first(gcols)) in names(df))) &&
        throw(ArgumentError("the file has no geometries (a plain table?); use load_distribution"))
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
