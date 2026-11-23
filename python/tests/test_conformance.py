"""Shared conformance cases (fixtures/cases.json): the same inputs must give the same tables in
Python, Julia and R. Python is the reference, so here this guards against unintended changes."""
import json
import math
import pathlib

import pytest

from dataeuropa.client import _distribution_rows, _facet_rows, _keywords, _sparql_rows, summarise_dataset

FIXTURES = pathlib.Path(__file__).resolve().parents[2] / "fixtures"
CASES = json.loads((FIXTURES / "cases.json").read_text(encoding="utf-8"))["cases"] if FIXTURES.exists() else []


def run(case):
    data = json.loads((FIXTURES / case["input"]).read_text(encoding="utf-8"))
    if case.get("select"):
        data = data[case["select"]]
    args = case.get("args") or {}
    kind = case["kind"]
    if kind == "summarise":
        return {"rows": [summarise_dataset(d, args["lang"]) for d in data]}
    if kind == "distributions":
        return {"rows": _distribution_rows(data, args["lang"])}
    if kind == "keywords":
        return {"values": _keywords(data, args["lang"])}
    if kind == "facets":
        return {"rows": _facet_rows(data, args["facet"], args["top"])}
    if kind == "sparql":
        res = _sparql_rows(data)
        return {"boolean": res} if isinstance(res, bool) else {"rows": res}
    raise ValueError(kind)


def same(a, b):
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool):
        return math.isclose(a, b, rel_tol=1e-9)
    return a == b


@pytest.mark.skipif(not CASES, reason="fixtures folder not available")
@pytest.mark.parametrize("case", CASES, ids=[c["name"] for c in CASES])
def test_conformance(case):
    expected = json.loads((FIXTURES / "expected" / f"{case['name']}.json").read_text(encoding="utf-8"))
    got = run(case)
    assert got.keys() == expected.keys()
    if "rows" in expected:
        assert len(got["rows"]) == len(expected["rows"])
        for i, (g, e) in enumerate(zip(got["rows"], expected["rows"])):
            for col, ev in e.items():
                assert same(g.get(col), ev), f"row {i}, column {col}: {g.get(col)!r} != {ev!r}"
    else:
        assert got == expected
