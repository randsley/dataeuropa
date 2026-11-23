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
    data = _readjson(case.input)
    sel = get(case, :select, nothing)
    sel === nothing || (data = data[Symbol(sel)])
    if kind == "file_format"
        return Dict("values" => [DE._file_format(get(r, :format, nothing), get(r, :media_type, nothing),
                                                 get(r, :url, nothing)) for r in data])
    end
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

# Rows as a vector of column => value lookups, whether they come from a DataFrame or a vector.
_rows(df::DataFrame) = [Dict(string(c) => r[c] for c in names(df)) for r in eachrow(df)]
_rows(v::AbstractVector) = [Dict(string(k) => val for (k, val) in r) for r in v]

if isdir(FIXTURES)
    @testset "conformance" begin
        for case in _readjson("cases.json").cases
            @testset "$(case.name)" begin
                expected = _readjson(joinpath("expected", "$(case.name).json"))
                got = _run(case)
                if haskey(expected, :columns)
                    @test got["columns"] == String.(expected.columns)
                end
                if haskey(expected, :rows)
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
