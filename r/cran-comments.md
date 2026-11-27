## Submission

First submission of dataeuropa, a client for the web services of data.europa.eu, the official
portal for European open data (Search API, Registry and SPARQL endpoint).

## R CMD check results

0 errors | 0 warnings | 1 note

* This is a new release.

## Test environments

* local: Windows 11, R 4.6.2
* GitHub Actions: ubuntu-latest, R release
* win-builder: R-devel
* mac-builder: R release

## Web services and files

* Tests and examples do not need the internet. Tests that call the portal are skipped on CRAN
  (`skip_on_cran()`); examples that call it run only in interactive sessions
  (`@examplesIf interactive()`), because the portal's response time is outside our control.
* Functions write only where the user says: `de_download()` has no default destination, and the
  optional response cache (off unless `de_cache_on()` is called) uses
  `tools::R_user_dir("dataeuropa", "cache")`. Tests and examples write only to `tempdir()`.
