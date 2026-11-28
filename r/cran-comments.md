## Submission

First submission of dataeuropa, a client for the web services of data.europa.eu, the official
portal for European open data (Search API, Registry and SPARQL endpoint).

## R CMD check results

0 errors | 0 warnings | 1 note

* This is a new release.
* "Possibly misspelled words in DESCRIPTION: SPARQL": SPARQL is the W3C query language for RDF
  data (https://www.w3.org/TR/sparql11-query/), the name of the portal's query endpoint.

## Test environments

* local: Windows 11, R 4.6.2 (R CMD check --as-cran, also with internet access blocked)
* win-builder: R-devel (2026-11-17 r90926 ucrt): 1 NOTE (the two items above)
* GitHub Actions: ubuntu-latest, R release (R CMD check --as-cran)
* R-universe, version 0.1.0 (the same code except that `de_download()` then had a default
  destination): Linux (R-devel, R-release), Windows (R-devel, R-release, R-oldrel), macOS
  (R-release, R-oldrel)

## Web services and files

* Tests and examples do not need the internet. Tests that call the portal are skipped on CRAN
  (`skip_on_cran()`); examples that call it run only in interactive sessions
  (`@examplesIf interactive()`), because the portal's response time is outside our control.
* Functions write only where the user says: `de_download()` has no default destination, and the
  optional response cache (off unless `de_cache_on()` is called) uses
  `tools::R_user_dir("dataeuropa", "cache")`. Tests and examples write only to `tempdir()`.
