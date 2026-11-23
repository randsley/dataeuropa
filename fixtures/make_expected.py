"""Regenerate fixtures/expected/*.json from the Python client, which is the reference implementation.

Run from the repo root:  python fixtures/make_expected.py
Review the diff: a change here changes what Julia and R are required to produce.
"""
from __future__ import annotations

import json
import pathlib
import sys

HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE.parent / "python" / "src"))

from dataeuropa.client import (_distribution_kind, _distribution_rows, _facet_rows, _file_format, _file_hash, _keywords,
                               _range_validator, _resume_action,  # noqa: E402
                               _read_table, _sparql_rows, summarise_dataset)


def plain(v):
    """A pandas/numpy cell as a JSON value; missing values become None."""
    import pandas as pd
    if v is None or (not isinstance(v, (list, dict)) and pd.isna(v)):
        return None
    if hasattr(v, "item"):          # numpy scalar
        v = v.item()
    if hasattr(v, "isoformat"):     # date / datetime
        return v.isoformat()
    return v


def table(df):
    return {"columns": [str(c) for c in df.columns],
            "rows": [{str(c): plain(v) for c, v in zip(df.columns, row)} for row in df.itertuples(index=False)]}


def run(case: dict):
    args = case.get("args") or {}
    kind = case["kind"]
    if kind == "read_file":
        return table(_read_table(HERE / case["input"], args["format"], args.get("sheet")))
    if kind == "file_hash":
        return {"values": [_file_hash(HERE / case["input"], a) for a in args["algorithms"]]}
    data = json.loads((HERE / case["input"]).read_text(encoding="utf-8"))
    if case.get("select"):
        data = data[case["select"]]
    if kind == "file_format":
        return {"values": [_file_format(r.get("format"), r.get("media_type"), r.get("url")) for r in data]}
    if kind == "distribution_kind":
        return {"values": [_distribution_kind(r.get("format"), r.get("media_type"), r.get("url"), r.get("download_url"))
                           for r in data]}
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
    raise ValueError(f"unknown kind {kind!r}")


def main() -> None:
    out = HERE / "expected"
    out.mkdir(exist_ok=True)
    for case in json.loads((HERE / "cases.json").read_text(encoding="utf-8"))["cases"]:
        path = out / f"{case['name']}.json"
        path.write_text(json.dumps(run(case), ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"wrote {path.relative_to(HERE.parent)}")


if __name__ == "__main__":
    main()
