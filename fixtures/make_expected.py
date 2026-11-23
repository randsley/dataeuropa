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

from dataeuropa.client import (_distribution_rows, _facet_rows, _keywords,  # noqa: E402
                               _sparql_rows, summarise_dataset)


def run(case: dict):
    data = json.loads((HERE / case["input"]).read_text(encoding="utf-8"))
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
