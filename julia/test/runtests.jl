using Test, DataEuropa, DataFrames, JSON3

const DE = DataEuropa
const LIVE = get(ENV, "DATAEUROPA_OFFLINE", "0") != "1"

@testset "offline helpers" begin
    @test pick_lang(JSON3.read("""{"pt":"olá","en":"hi"}"""), "pt") == "olá"
    @test pick_lang(JSON3.read("""{"pt":"olá","en":"hi"}"""), "fr") == "hi"
    @test pick_lang(JSON3.read("""{"de":"hallo"}"""), "fr") == "hallo"
    @test ismissing(pick_lang(nothing))
    f = DE._facets(Dict("catalog" => ["a"]), (country=["PT", "ES"], hvd=true, format="CSV", license=nothing))
    @test f["country"] == ["pt", "es"] && f["is_hvd"] == ["true"] && f["format"] == ["CSV"] && f["catalog"] == ["a"]
    d = JSON3.read("""{"id":"x","title":{"en":"T"},"country":{"id":"pt"},"catalog":{"id":"c"},
        "distributions":[{"format":{"id":"CSV"}},{"format":{"id":"JSON"}},{}],"landing_page":[{"resource":"http://lp"}]}""")
    s = DE.summarise_dataset(d)
    @test s.formats == ["CSV", "JSON"] && s.n_distributions == 3 && s.landing_page == "http://lp"
end

LIVE && @testset "live API" begin
    df = search_datasets("water"; country="pt", format="CSV", limit=3)
    @test 0 < nrow(df) <= 3
    @test metadata(df, "count") > 0
    id = df.id[1]
    @test get_dataset(id).id == id
    dist = distributions(id)
    @test nrow(dist) > 0 && "url" in names(dist)
    @test occursin("dcat", lowercase(get_rdf(id)))
    fv = facet_values("country"; top=5)
    @test nrow(fv) == 5
    @test count_datasets("water"; country="de") > 0
    rows = collect(iter_datasets("water"; country="mt", max_results=1200, page_size=500))
    @test length(unique(r.id for r in rows)) == length(rows) > 0
    t = sparql("SELECT (COUNT(?s) AS ?n) WHERE { ?s a <http://www.w3.org/ns/dcat#Dataset> }")
    @test parse(Int, t.n[1]) > 1_000_000
    @test sparql("ASK { ?s ?p ?o }") === true
    @test "pt" in catalogues() || length(catalogues()) > 100
end
