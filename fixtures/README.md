# Shared test fixtures

The same API responses must give the same tables in Python, Julia and R. This folder holds the
inputs, the expected outputs, and the list of cases that all three test suites run.

| Path | What it is |
|---|---|
| `responses/*.json` | Real API responses recorded by `record.py`, trimmed to stay small |
| `responses/edge_cases.json` | Hand-written records for cases the live data rarely shows (missing fields, language fallback, ties, unbound SPARQL variables) |
| `cases.json` | The cases: which input to read, which conversion to run, with which arguments |
| `expected/<case>.json` | Expected output for each case, generated from the Python client |
| `record.py` | Re-records `responses/` from the live API |
| `make_expected.py` | Regenerates `expected/` from the Python client |

Python is the reference implementation, so `expected/` is generated from it. The Python tests
then guard against unintended changes, and the Julia and R tests check that they match it.

## Conversions under test

| `kind` | Python | Julia | R |
|---|---|---|---|
| `summarise` | `summarise_dataset` | `summarise_dataset` | `de_summarise` |
| `distributions` | `_distribution_rows` | `_distribution_table` | `de_distribution_table` |
| `keywords` | `_keywords` | `_keywords` | `de_keywords` |
| `facets` | `_facet_rows` | `_facet_table` | `de_facet_table` |
| `sparql` | `_sparql_rows` | `_sparql_result` | `de_sparql_table` |

## How results are compared

- Row count and row order must match. Every column in the expected rows must match.
- `null`, `None`, `missing`, `nothing` and `NA` all count as missing.
- Numbers are compared as floating point (R stores counts and sizes as doubles).
- `formats` is a list. R stores it as a comma-separated string, which the R test splits.
- SPARQL ASK results compare as `{"boolean": ...}`; keyword lists as `{"values": [...]}`.

## Running the tests

They run with each language's normal offline tests (see the top-level `CLAUDE.md` or the package
READMEs). R runs them from a source checkout only, because this folder is not part of the R package.

## Changing behaviour

1. Change the Python client.
2. `python fixtures/make_expected.py`, then review the diff in `expected/`.
3. Make Julia and R pass.

To add a case, add an entry to `cases.json` (and, if needed, data to `edge_cases.json`), then run
`make_expected.py`. No test code changes are needed.

To refresh the recorded responses: `python fixtures/record.py`, then `make_expected.py`. The portal's
data changes over time, so expect the diff to be large.
