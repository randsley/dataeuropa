"""Shared conformance cases (fixtures/cases.json): the same inputs must give the same tables in
Python, Julia and R. Python is the reference, so here this guards against unintended changes."""
import json
import math
import pathlib

import pytest

from dataeuropa.client import (_distribution_rows, _facet_rows, _file_format, _file_hash, _keywords,
                               _range_validator, _resume_action, _read_table,
                               _sparql_rows, summarise_dataset)

FIXTURES = pathlib.Path(__file__).resolve().parents[2] / "fixtures"
CASES = json.loads((FIXTURES / "cases.json").read_text(encoding="utf-8"))["cases"] if FIXTURES.exists() else []


def plain(v):
    """A pandas/numpy cell as a plain value; missing values become None."""
    import pandas as pd
    if v is None or (not isinstance(v, (list, dict)) and pd.isna(v)):
        return None
    if hasattr(v, "item"):
        v = v.item()
    return v.isoformat() if hasattr(v, "isoformat") else v


def run(case):
    args = case.get("args") or {}
    kind = case["kind"]
    if kind == "read_file":
        df = _read_table(FIXTURES / case["input"], args["format"], args.get("sheet"))
        return {"columns": [str(c) for c in df.columns],
                "rows": [{str(c): plain(v) for c, v in zip(df.columns, r)} for r in df.itertuples(index=False)]}
    if kind == "file_hash":
        return {"values": [_file_hash(FIXTURES / case["input"], a) for a in args["algorithms"]]}
    data = json.loads((FIXTURES / case["input"]).read_text(encoding="utf-8"))
    if case.get("select"):
        data = data[case["select"]]
    if kind == "file_format":
        return {"values": [_file_format(r.get("format"), r.get("media_type"), r.get("url")) for r in data]}
    if kind == "range_validator":
        return {"values": [_range_validator(r["etag"], r["last_modified"]) for r in data]}
    if kind == "resume_action":
        return {"values": [_resume_action(r["status"], r["content_range"], r["offset"]) for r in data]}
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
    if "columns" in expected:
        assert got["columns"] == expected["columns"]
    if "rows" in expected:
        assert len(got["rows"]) == len(expected["rows"])
        for i, (g, e) in enumerate(zip(got["rows"], expected["rows"])):
            for col, ev in e.items():
                assert same(g.get(col), ev), f"row {i}, column {col}: {g.get(col)!r} != {ev!r}"
    else:
        assert got == expected
