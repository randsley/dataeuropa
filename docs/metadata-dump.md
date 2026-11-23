# data.europa.eu full metadata dump: notes

Checked 23 Nov 2026. Source page: https://data.europa.eu/en/download-datasets

## What it is
- File: https://data.europa.eu/data_dump/data_europa_eu_dump.zip
- Size: 9,443,378,160 bytes (9.44 GB), `application/zip`, server supports HTTP range requests.
- Last modified: 8 Sep 2026 (23:31 GMT per the HTTP header), so about 11 weeks older than the live API at the time of checking.
- The page labels it English metadata for all of data.europa.eu. It does not state the RDF serialisation, update frequency or licence.
- Smaller English dumps on the same page (studies, news, data stories, images; last modified 1 Oct 2026) and 10 archive ZIPs covering Dec 2025 to Sep 2026 plus one "to December 2025" archive.

## What I verified by reading the zip directory remotely (about 1 MB transferred, nothing downloaded)
- 7,056 entries: 6,830 `.trig` files, 211 directories, 15 `.log` files.
- One folder per catalogue (e.g. `gdi-de` 2,143 files, `govdata` 615, `datos-gob-es` 485, `dane-gov-pl` 362, `dati-gov-it` 294, `data-gov-uk` 293).
- Each folder has a `Catalog_<id>.trig` plus `Dataset_<uuid>.trig` files. Largest file seen: `gdi-de/Catalog_gdi-de.trig`, about 109 MB.
- About 54.6 GB uncompressed.
- One sample file (`etf/Dataset_bd91d0bb-...trig`, 78 KB) held 2 datasets as named graphs, with their distributions, contact points (vCard) and data-theme concepts.

## Not verified
- How many datasets the dump contains in total versus the roughly 1.9 M records the portal reports (about 6,800 data files suggests batching or partial coverage).
- Licence of the dump itself and how often it is regenerated.

## When it is useful
- Whole-portal analysis offline (formats, licences, publishers, quality scores per country) without API paging or slow SPARQL group-bys (10 to 40 s per query).
- A dated, citable snapshot for papers.
- A local index: convert once to Parquet or DuckDB, then query from Python, Julia or R.

## When it is not
- Discovery and download of data: the live Search API is current to the day, and the dump holds metadata only (files stay on publishers' servers).
- Cost: ~10 GB download, ~55 GB unpacked, needs RDF tooling (Oxigraph or Apache Jena `riot` are far faster than rdflib at this scale).

## Possible follow-up (not started)
Streaming TriG-to-Parquet converter (Python first, then Julia and R loaders), tested on a sample of catalogues to measure coverage before a full run. Keep out of the core packages; make it an optional `load_dump()` helper.

## Reproduce the directory check
Open the zip with Python's `zipfile` over a file-like object that issues `Range: bytes=a-b` requests; `ZipFile(...).infolist()` then lists every entry after fetching only the central directory.
