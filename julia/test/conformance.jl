# Shared conformance cases (fixtures/cases.json): the same inputs must give the same tables in
# Python, Julia and R. Expected outputs come from the Python reference (fixtures/make_expected.py).

const FIXTURES = normpath(joinpath(@__DIR__, "..", "..", "fixtures"))

_readjson(path) = JSON3.read(read(joinpath(FIXTURES, path), String))

# Bring a Julia value and an expected JSON value to comparable plain values.
_norm(x::Missing) = nothing
_norm(x::Nothing) = nothing
_norm(x::Bool) = x
_norm(x::Real) = Float64(x)
_norm(x::AbstractString) = String(x)
_norm(x::Union{AbstractVector,JSON3.Array}) = Any[_norm(v) for v in x]
_norm(x) = x

_same(a, b) = (a isa Float64 && b isa Float64) ? isapprox(a, b; rtol=1e-9) : isequal(a, b)

function _run(case)
    args = get(case, :args, Dict())
    kind = case.kind
    if kind == "read_file"
        sheet = get(args, :sheet, nothing)
        df = DE._read_table(joinpath(FIXTURES, case.input), args.format; sheet=sheet === nothing ? nothing : String(sheet))
        return Dict("columns" => names(df), "rows" => df)
    end
    if kind == "file_hash"
        return Dict("values" => [DE._file_hash(joinpath(FIXTURES, case.input), String(a)) for a in args.algorithms])
    end
    if kind == "read_geo"
        arg(k) = (v = get(args, k, nothing); v isa AbstractString ? String(v) : v)
        df = try
            Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                DE._read_geodata(joinpath(FIXTURES, case.input), arg(:layer), arg(:crs))
            end
        catch e
            e isa ArgumentError || rethrow()
            nothing
        end
        cols = get(args, :columns, nothing)
        return df === nothing ? Dict("error" => true) : DE._geo_summary(df, cols === nothing ? nothing : String.(cols))
    end
    data = _readjson(case.input)
    sel = get(case, :select, nothing)
    sel === nothing || (data = data[Symbol(sel)])
    if kind == "file_format"
        return Dict("values" => [DE._file_format(get(r, :format, nothing), get(r, :media_type, nothing),
                                                 get(r, :url, nothing)) for r in data])
    end
    kind == "geo_format" &&
        return Dict("values" => [DE._geo_format(get(r, :format, nothing), get(r, :media_type, nothing),
                                                get(r, :url, nothing)) for r in data])
    if kind == "geo_member"
        return Dict("values" => map(data) do r
            try
                Any[DE._geo_member(String.(r.names), r.layer === nothing ? nothing : String(r.layer))...]
            catch e
                e isa ArgumentError || rethrow()
                "error"
            end
        end)
    end
    kind == "distribution_kind" &&
        return Dict("values" => [DE._distribution_kind(get(r, :format, nothing), get(r, :media_type, nothing),
                                                       get(r, :url, nothing), get(r, :download_url, nothing)) for r in data])
    kind == "range_validator" &&
        return Dict("values" => [DE._range_validator(r.etag, r.last_modified) for r in data])
    kind == "resume_action" &&
        return Dict("values" => [DE._resume_action(r.status, r.content_range, r.offset) for r in data])
    kind == "summarise" && return Dict("rows" => [Dict(pairs(DE.summarise_dataset(d, args.lang))) for d in data])
    kind == "distributions" && return Dict("rows" => DE._distribution_table(data, args.lang))
    kind == "keywords" && return Dict("values" => DE._keywords(data, args.lang))
    kind == "facets" && return Dict("rows" => DE._facet_table(data, args.facet, args.top))
    if kind == "sparql"
        res = DE._sparql_result(data)
        return res isa Bool ? Dict("boolean" => res) : Dict("rows" => res)
    end
    error("unknown kind $kind")
end

# A geodata summary against the expected one; bounds to within 1e-9 (relative).
function _check_geo(got, expected)
    if get(expected, :error, false) == true
        @test get(got, "error", false) == true
        return
    end
    @test !haskey(got, "error")
    haskey(got, "error") && return
    haskey(expected, :columns) && @test got["columns"] == String.(expected.columns)
    for (col, ev) in pairs(expected.values)
        @test _norm(got["values"][String(col)]) == _norm(ev)
    end
    @test got["nrow"] == expected.nrow
    @test got["geometry_types"] == String.(expected.geometry_types)
    @test _norm(got["crs"]) == _norm(expected.crs)
    @test all(isapprox.(Float64.(got["bounds"]), Float64.(expected.bounds); rtol=1e-9))
end

# Rows as a vector of column => value lookups, whether they come from a DataFrame or a vector.
_rows(df::DataFrame) = [Dict(string(c) => r[c] for c in names(df)) for r in eachrow(df)]
_rows(v::AbstractVector) = [Dict(string(k) => val for (k, val) in r) for r in v]

if isdir(FIXTURES)
    @testset "conformance" begin
        for case in _readjson("cases.json").cases
            @testset "$(case.name)" begin
                expected = _readjson(joinpath("expected", "$(case.name).json"))
                got = _run(case)
                haskey(expected, :columns) && case.kind != "read_geo" && @test got["columns"] == String.(expected.columns)
                if case.kind == "read_geo"
                    _check_geo(got, expected)
                elseif haskey(expected, :rows)
                    grows, erows = _rows(got["rows"]), expected.rows
                    @test length(grows) == length(erows)
                    for (i, (g, e)) in enumerate(zip(grows, erows)), (col, ev) in pairs(e)
                        gv = _norm(get(g, string(col), nothing))
                        ok = _same(gv, _norm(ev))
                        ok || @info "mismatch" case.name i col got=gv expected=_norm(ev)
                        @test ok
                    end
                elseif haskey(expected, :values)
                    @test _norm(got["values"]) == _norm(expected.values)
                else
                    @test got["boolean"] === expected.boolean
                end
            end
        end
    end
else
    @info "fixtures folder not found; skipping conformance tests"
end
