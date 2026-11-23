import pytest

import dataeuropa as de
from dataeuropa.client import _bbox_params, _build_facets, pick_lang, summarise_dataset


def test_pick_lang():
    assert pick_lang({"pt": "olá", "en": "hi"}, "pt") == "olá"
    assert pick_lang({"pt": "olá", "en": "hi"}, "fr") == "hi"
    assert pick_lang({"de": "hallo"}, "fr") == "hallo"
    assert pick_lang(None) is None


def test_build_facets():
    f = _build_facets({"catalog": ["a"]}, country=["PT", "ES"], hvd=True, format="CSV", license=None)
    assert f == {"catalog": ["a"], "country": ["pt", "es"], "is_hvd": ["true"], "format": ["CSV"]}
    assert _build_facets(None) is None


def test_summarise_dataset():
    d = {"id": "x", "title": {"en": "T"}, "country": {"id": "pt"}, "catalog": {"id": "c"},
         "distributions": [{"format": {"id": "CSV"}}, {"format": {"id": "JSON"}}, {}],
         "landing_page": [{"resource": "http://lp"}]}
    s = summarise_dataset(d)
    assert s["formats"] == ["CSV", "JSON"] and s["n_distributions"] == 3
    assert s["landing_page"] == "http://lp" and s["country"] == "pt"


def test_bbox_params():
    assert _bbox_params((20, 59.7, 31.6, 70.1)) == {
        "bboxMinLon": 20.0, "bboxMinLat": 59.7, "bboxMaxLon": 31.6, "bboxMaxLat": 70.1}
    for bad in [(1, 2, 3), (1, 2, 3, 4, 5), ("a", 1, 2, 3), (10, 0, 5, 1), (0, 10, 1, 5),
                (-200, 0, 0, 1), (0, 0, 1, 95)]:
        with pytest.raises(ValueError):
            _bbox_params(bad)


live = pytest.mark.live


@live
def test_live_search_and_dataset():
    df = de.search_datasets("water", country="pt", format="CSV", limit=3, as_dataframe=False)
    assert 0 < len(df) <= 3
    did = df[0]["id"]
    ds = de.get_dataset(did)
    assert ds["id"] == did
    dist = de.distributions(did, as_dataframe=False)
    assert dist and "url" in dist[0]
    assert de.get_rdf(did).startswith("PREFIX") or "@prefix" in de.get_rdf(did)


@live
def test_live_facets_count_scroll():
    fv = de.facet_values("country", top=5)
    assert len(fv) == 5
    assert de.count("water", country="de") > 0
    rows = list(de.iter_datasets("water", country="mt", max_results=1200, page_size=500))
    assert len({r["id"] for r in rows}) == len(rows) > 0


@live
def test_live_sparql():
    t = de.sparql("SELECT (COUNT(?s) AS ?n) WHERE { ?s a <http://www.w3.org/ns/dcat#Dataset> }")
    assert int(t["n"][0]) > 1_000_000
    assert de.sparql("ASK { ?s ?p ?o }") is True


@live
def test_live_bbox_filters():
    # Overlap match: a box over Finland returns fewer records than no box, and more than none.
    total = de.count()
    n = de.count(bbox=(20, 59.7, 31.6, 70.1))
    assert 0 < n < total
