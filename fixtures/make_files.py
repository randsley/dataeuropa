"""Write the sample files in fixtures/files/ used by the load_distribution conformance cases.

Run from the repo root:  python fixtures/make_files.py   (needs openpyxl and pyarrow)
The files are small and committed; rerun only to change them, then run make_expected.py.
"""
from __future__ import annotations

import json
import pathlib

import openpyxl
import pyarrow as pa
import pyarrow.parquet as pq

OUT = pathlib.Path(__file__).parent / "files"

# UTF-8 with a byte-order mark; a quoted comma, empty cells, a date, booleans, non-ASCII text.
COMMA_CSV = (
    "id,name,value,date,flag,note\n"
    '1,"Lisboa, PT",3.5,2024-01-31,true,Zürich\n'
    "2,Porto,,2024-02-29,false,\n"
    "3,Faro,10,2024-03-01,true,plain\n"
)
# Latin-1, semicolons; decimal commas are not converted, so `share` stays text.
SEMICOLON_CSV = (
    "city;population;share\n"
    "München;1512491;12,5\n"
    "Köln;1084831;7,25\n"
)
RECORDS = [
    {"id": 1, "name": "a", "score": 0.5, "ok": True},
    {"id": 2, "name": "b", "ok": False, "extra": "only here"},
    {"id": 3, "name": None, "score": 2, "ok": True},
]
WRAPPED = {"meta": {"count": 2, "source": "test"},
           "data": [{"code": "PT", "value": 1}, {"code": "ES", "value": 2.5}]}


def main() -> None:
    OUT.mkdir(exist_ok=True)
    (OUT / "comma.csv").write_bytes(b"\xef\xbb\xbf" + COMMA_CSV.encode("utf-8"))
    (OUT / "semicolon.csv").write_bytes(SEMICOLON_CSV.encode("latin-1"))
    (OUT / "records.json").write_text(json.dumps(RECORDS, indent=1) + "\n", encoding="utf-8")
    (OUT / "wrapped.json").write_text(json.dumps(WRAPPED, indent=1) + "\n", encoding="utf-8")

    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "First"
    for row in [["region", "count", "rate"], ["north", 10, 0.25], ["south", None, 1.5], ["east", 7, None]]:
        ws.append(row)
    ws2 = wb.create_sheet("Second")
    for row in [["k", "v"], ["x", 1], ["y", 2]]:
        ws2.append(row)
    wb.save(OUT / "table.xlsx")

    table = pa.table({"id": pa.array([1, 2, 3], pa.int64()),
                      "value": pa.array([1.5, None, -2.0], pa.float64()),
                      "label": pa.array(["one", "two", None], pa.string())})
    pq.write_table(table, OUT / "table.parquet")
    for f in sorted(OUT.iterdir()):
        print(f"wrote {f.relative_to(OUT.parent.parent)} ({f.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
