#' @keywords internal
"_PACKAGE"

SEARCH_URL <- "https://data.europa.eu/api/hub/search"
REPO_URL   <- "https://data.europa.eu/api/hub/repo"
SPARQL_URL <- "https://data.europa.eu/sparql"

.facet_aliases <- c(country = "country", catalog = "catalog", catalogue = "catalog",
                    format = "format", license = "license", licence = "license",
                    category = "categories", categories = "categories", publisher = "publisher",
                    keyword = "keywords", keywords = "keywords", hvd = "is_hvd",
                    source_type = "source_type", super_catalog = "superCatalog")

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

de_req <- function(url) {
  httr2::request(url) |>
    httr2::req_user_agent("dataeuropa-r/0.1 (+https://data.europa.eu)") |>
    httr2::req_timeout(as.numeric(Sys.getenv("DATAEUROPA_TIMEOUT", "60"))) |>
    httr2::req_retry(max_tries = 4, backoff = function(i) 0.8 * 2^(i - 1)) |>
    httr2::req_error(body = function(resp) {
      b <- tryCatch(httr2::resp_body_json(resp)$message, error = function(e) NULL)
      if (is.null(b)) NULL else b
    })
}

de_json <- function(resp) {
  jsonlite::fromJSON(httr2::resp_body_string(resp), simplifyVector = FALSE)
}

# ---------------------------------------------------------------- response cache

# Set by de_cache_on() / de_cache_off(); NULL means "use the environment variable".
.de_cache <- new.env(parent = emptyenv())
.de_cache_ttl_default <- 86400  # one day, in seconds

de_cache_enabled <- function() {
  if (!is.null(.de_cache$on)) return(.de_cache$on)
  tolower(trimws(Sys.getenv("DATAEUROPA_CACHE"))) %in% c("1", "true", "yes")
}

de_cache_dir <- function() {
  if (!is.null(.de_cache$dir)) return(.de_cache$dir)
  d <- Sys.getenv("DATAEUROPA_CACHE_DIR")
  if (nzchar(d)) d else tools::R_user_dir("dataeuropa", "cache")
}

de_cache_ttl <- function() {
  if (!is.null(.de_cache$ttl)) return(as.numeric(.de_cache$ttl))
  t <- Sys.getenv("DATAEUROPA_CACHE_TTL")
  if (nzchar(t)) as.numeric(t) else .de_cache_ttl_default
}

#' Turn the on-disk response cache on or off, or empty it
#'
#' Cached: dataset records ([de_get_dataset()], [de_distributions()]), the catalogue list
#' ([de_catalogues()]), and searches with `limit = 0` ([de_facet_values()], [de_count()]). Other
#' searches, SPARQL and file downloads are never cached.
#'
#' The cache is off unless `de_cache_on()` is called or the environment variable
#' `DATAEUROPA_CACHE=1` is set. `de_cache_off()` turns it off for the session; cached files stay
#' until `de_clear_cache()`.
#'
#' @param dir Cache folder. Defaults to `DATAEUROPA_CACHE_DIR`, else
#'   `tools::R_user_dir("dataeuropa", "cache")`.
#' @param ttl How long a response stays valid, in seconds. Defaults to `DATAEUROPA_CACHE_TTL`,
#'   else one day.
#' @return `de_cache_on()`: the cache folder, invisibly. `de_cache_off()`: `NULL`, invisibly.
#'   `de_clear_cache()`: the number of responses deleted.
#' @examples
#' de_cache_on(dir = file.path(tempdir(), "dataeuropa-cache"), ttl = 3600)
#' de_clear_cache()
#' de_cache_off()
#' @export
de_cache_on <- function(dir = NULL, ttl = NULL) {
  .de_cache$on <- TRUE
  .de_cache$dir <- dir
  .de_cache$ttl <- ttl
  path <- de_cache_dir()
  dir.create(path, recursive = TRUE, showWarnings = FALSE)
  invisible(path)
}

#' @rdname de_cache_on
#' @export
de_cache_off <- function() {
  .de_cache$on <- FALSE
  invisible(NULL)
}

#' @rdname de_cache_on
#' @export
de_clear_cache <- function() {
  path <- de_cache_dir()
  if (!dir.exists(path)) return(0L)
  files <- list.files(path, pattern = "^[0-9a-f]{64}\\.json$", full.names = TRUE)
  unlink(files)
  length(files)
}

# File name of a cached response: SHA-256 of the URL and its sorted query parameters.
de_cache_key <- function(url, query = list()) {
  q <- if (length(query)) {
    keys <- sort(names(query))
    paste0(keys, "=", vapply(keys, function(k) paste(as.character(query[[k]]), collapse = ","), ""),
           collapse = "&")
  } else ""
  paste0(paste0(as.character(openssl::sha256(paste0(url, "?", q)))), ".json")
}

# GET a response body as text (a stand-in for tests replaces this).
de_http_get <- function(url, query = list()) {
  req <- do.call(httr2::req_url_query, c(list(de_req(url)), query))
  httr2::resp_body_string(httr2::req_perform(req))
}

# GET a JSON response, from the cache when it is on, `cacheable` and fresh.
de_get_json <- function(url, query = list(), cacheable = FALSE) {
  path <- if (cacheable && de_cache_enabled()) file.path(de_cache_dir(), de_cache_key(url, query)) else NULL
  ttl <- de_cache_ttl()   # ttl 0: never fresh, even when the file time is a little ahead of the clock
  if (!is.null(path) && ttl > 0 && file.exists(path) &&
      difftime(Sys.time(), file.mtime(path), units = "secs") < ttl) {
    body <- readChar(path, file.info(path)$size, useBytes = TRUE)
    Encoding(body) <- "UTF-8"
  } else {
    body <- de_http_get(url, query)
    if (!is.null(path)) {
      dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
      tmp <- paste0(path, ".", Sys.getpid(), ".tmp")   # write, then rename, so readers never see half a file
      writeBin(charToRaw(enc2utf8(body)), tmp)
      file.rename(tmp, path)
    }
  }
  jsonlite::fromJSON(body, simplifyVector = FALSE)
}

#' Collapse a multilingual `{lang: text}` list to one string
#'
#' @param x A named list of translations (or a string).
#' @param lang Preferred language code; falls back to English, then any.
#' @return A character scalar, or `NA_character_`.
#' @examples
#' de_pick_lang(list(de = "Wasser", en = "Water"), lang = "de")
#' de_pick_lang(list(de = "Wasser", en = "Water"), lang = "fr")   # falls back to English
#' de_pick_lang(list(pt = "Qualidade do ar"))                     # else any language
#' @export
de_pick_lang <- function(x, lang = "en") {
  if (is.null(x) || length(x) == 0) return(NA_character_)
  if (is.character(x) && is.null(names(x))) return(x[[1]])
  if (is.list(x) && is.null(names(x))) return(de_pick_lang(x[[1]], lang))
  for (k in c(lang, "en")) if (!is.null(x[[k]]) && nzchar(x[[k]])) return(as.character(x[[k]]))
  for (v in x) if (is.character(v) && nzchar(v)) return(v)
  NA_character_
}

de_facets <- function(facets = NULL, ...) {
  named <- list(...)
  out <- lapply(facets %||% list(), as.character)
  for (k in names(named)) {
    v <- named[[k]]
    if (is.null(v)) next
    fid <- unname(.facet_aliases[k])
    vals <- if (is.logical(v)) tolower(as.character(v)) else as.character(v)
    if (fid == "country") vals <- tolower(vals)
    out[[fid]] <- c(out[[fid]], vals)
  }
  if (length(out) == 0) NULL else out
}

# Check c(min_lon, min_lat, max_lon, max_lat) and return the Search API parameters. The API ignores
# an incomplete box and rejects min > max with an unhelpful 400, so check here.
de_bbox_params <- function(bbox) {
  if (!is.numeric(bbox) || length(bbox) != 4 || anyNA(bbox))
    stop("bbox must be 4 numbers: c(min_lon, min_lat, max_lon, max_lat)", call. = FALSE)
  bbox <- as.numeric(bbox)
  if (!(-180 <= bbox[1] && bbox[1] <= bbox[3] && bbox[3] <= 180))
    stop("bbox longitudes must satisfy -180 <= min_lon <= max_lon <= 180", call. = FALSE)
  if (!(-90 <= bbox[2] && bbox[2] <= bbox[4] && bbox[4] <= 90))
    stop("bbox latitudes must satisfy -90 <= min_lat <= max_lat <= 90", call. = FALSE)
  names(bbox) <- c("bboxMinLon", "bboxMinLat", "bboxMaxLon", "bboxMaxLat")
  as.list(bbox)
}

#' Raw Search API call
#'
#' Returns the `result` object of the Search API as a nested list
#' (`count`, `results`, `facets`, ...).
#'
#' @param q Free-text query.
#' @param filters Document type: "dataset" (default), "catalogue", "dataservice", "resource"...
#' @param facets Named list of facet filters, e.g. `list(country = "pt")`.
#' @param limit Results per page (0-1000).
#' @param page Zero-based page.
#' @param sort e.g. `"modified+desc"`.
#' @param country,catalog,format,license,category,publisher,keywords,hvd Convenience facet filters.
#'   `country` takes ISO-2 codes, `format` ids like "CSV", `category` DCAT-AP theme codes ("ENVI").
#' @param min_date,max_date,date_type Date range; `date_type` one of issued, modified, temporal.
#' @param bbox Numeric `c(min_lon, min_lat, max_lon, max_lat)` in WGS84 degrees. A dataset matches
#'   when its spatial extent overlaps the box, so datasets covering all of Europe or the world match
#'   any box. Datasets without a spatial extent (about half the portal) never match.
#' @param aggregation Return facet counts?
#' @param extra Named list of additional raw query parameters.
#' @details With `limit = 0` the result can come from the response cache (see [de_cache_on()]).
#' @return The `result` object of the response, a nested list with `count`, `results` (the
#'   records), `facets` when `aggregation = TRUE`, and `scrollId` in scroll mode.
#' @examplesIf interactive()
#' res <- de_search("air quality", country = "pt", limit = 5)
#' res$count
#' de_pick_lang(res$results[[1]]$title)
#' @export
de_search <- function(q = NULL, filters = "dataset", facets = NULL, limit = 10, page = 0,
                      sort = NULL, country = NULL, catalog = NULL, format = NULL, license = NULL,
                      category = NULL, publisher = NULL, keywords = NULL, hvd = NULL,
                      min_date = NULL, max_date = NULL, date_type = NULL, bbox = NULL,
                      aggregation = FALSE, extra = list()) {
  p <- list(limit = limit, page = page, aggregation = tolower(as.character(aggregation)))
  if (!is.null(q) && nzchar(q)) p$q <- q
  if (!is.null(filters)) p$filters <- paste(filters, collapse = ",")
  fac <- de_facets(facets, country = country, catalog = catalog, format = format, license = license,
                   category = category, publisher = publisher, keywords = keywords, hvd = hvd)
  if (!is.null(fac)) p$facets <- as.character(jsonlite::toJSON(fac, auto_unbox = FALSE))
  if (!is.null(sort)) p$sort <- paste(sort, collapse = ",")
  if (!is.null(min_date)) p$minDate <- min_date
  if (!is.null(max_date)) p$maxDate <- max_date
  if (!is.null(date_type)) p$dateType <- date_type
  if (!is.null(bbox)) p <- c(p, de_bbox_params(bbox))
  p <- c(p, extra)
  # limit = 0 (facet counts, hit counts) carries no records, so it may come from the cache.
  de_get_json(paste0(SEARCH_URL, "/search"), p, cacheable = identical(as.numeric(limit), 0))$result
}

chr <- function(x) if (is.null(x) || length(x) == 0) NA_character_ else as.character(x[[1]])

de_summarise <- function(d, lang = "en") {
  dists <- d$distributions %||% list()
  fmts <- sort(unique(unlist(lapply(dists, function(x) x$format$id))))
  lp <- d$landing_page
  data.frame(
    id = chr(d$id), title = de_pick_lang(d$title, lang),
    description = de_pick_lang(d$description, lang),
    country = chr(d$country$id), catalog = chr(d$catalog$id), publisher = chr(d$publisher$name),
    issued = chr(d$issued), modified = chr(d$modified),
    formats = paste(fmts, collapse = ","), n_distributions = length(dists),
    is_hvd = if (is.null(d$is_hvd)) NA else as.logical(d$is_hvd), quality_score = suppressWarnings(as.numeric(chr(d$quality_meas$scoring))),
    landing_page = if (length(lp)) chr(lp[[1]]$resource) else NA_character_,
    portal_url = paste0("https://data.europa.eu/data/datasets/", chr(d$id)),
    stringsAsFactors = FALSE)
}

bind_rows_base <- function(rows) {
  if (length(rows) == 0) return(data.frame())
  do.call(rbind, rows)
}

#' Search datasets and return a data frame
#'
#' Accepts all arguments of [de_search()]. Total hits are in `attr(x, "count")`.
#' @param lang Language for titles/descriptions.
#' @inheritParams de_search
#' @param ... Passed to [de_search()].
#' @return A data frame with one row per dataset: `id`, `title`, `description`, `country`,
#'   `catalog`, `publisher`, `issued`, `modified`, `formats`, `n_distributions`, `is_hvd`,
#'   `quality_score`, `landing_page` and `portal_url`. The total number of hits is in
#'   `attr(x, "count")`.
#' @examplesIf interactive()
#' ds <- de_search_datasets("air quality", country = "pt", format = "CSV", limit = 5)
#' ds[, c("id", "title", "formats")]
#' attr(ds, "count")
#' @export
de_search_datasets <- function(q = NULL, ..., lang = "en") {
  res <- de_search(q, ...)
  out <- bind_rows_base(lapply(res$results, de_summarise, lang = lang))
  attr(out, "count") <- res$count
  out
}

#' Fetch many datasets with the scroll API
#'
#' @param max_results Stop after this many records.
#' @param page_size Records per request (max 1000).
#' @param raw Return the raw list of records instead of a data frame.
#' @inheritParams de_search_datasets
#' @return A data frame with the columns of [de_search_datasets()], one row per dataset, or with
#'   `raw = TRUE` a list of the raw records. At most `max_results` either way.
#' @examplesIf interactive()
#' ds <- de_fetch_datasets(country = "pt", max_results = 2500, page_size = 1000)   # three requests
#' nrow(ds)
#' @export
de_fetch_datasets <- function(q = NULL, ..., max_results = 1000, page_size = 500, lang = "en", raw = FALSE) {
  args <- list(...)
  args$limit <- NULL; args$page <- NULL
  args$extra <- c(args$extra %||% list(), list(scroll = "true"))
  res <- do.call(de_search, c(list(q = q, limit = min(page_size, 1000)), args))
  out <- list()
  repeat {
    out <- c(out, res$results)
    sid <- res$scrollId
    if (length(out) >= max_results || length(res$results) == 0 || is.null(sid)) break
    req <- de_req(paste0(SEARCH_URL, "/scroll")) |> httr2::req_url_query(scrollId = sid)
    res <- de_json(httr2::req_perform(req))$result
  }
  out <- utils::head(out, max_results)
  if (raw) out else bind_rows_base(lapply(out, de_summarise, lang = lang))
}

#' Number of hits for a query (no records transferred)
#' @inheritParams de_search_datasets
#' @return An integer.
#' @examplesIf interactive()
#' de_count(country = "pt")
#' de_count("water", format = "CSV")
#' @export
de_count <- function(q = NULL, ...) as.integer(de_search(q, limit = 0, ...)$count)

#' Full metadata for one dataset
#'
#' @param id Dataset id as shown in search results.
#' @param raw If `TRUE` return the untouched nested list.
#' @param lang Preferred language.
#' @return A list with `summary` (a one-row data frame with the columns of
#'   [de_search_datasets()]), `keywords` (a character vector) and `raw` (the record as a nested
#'   list). With `raw = TRUE`, the record alone.
#' @examplesIf interactive()
#' d <- de_get_dataset("6689f1686e4bd9bc98ed011b")
#' d$summary$title
#' d$summary[, c("publisher", "modified", "formats")]
#' @export
de_get_dataset <- function(id, raw = FALSE, lang = "en") {
  d <- de_get_json(paste0(SEARCH_URL, "/datasets/", id), cacheable = TRUE)$result
  if (raw) return(d)
  list(summary = de_summarise(d, lang), keywords = de_keywords(d, lang), raw = d)
}

# Keyword labels in `lang`, plus those with no language tag.
de_keywords <- function(d, lang = "en") {
  kw <- unlist(lapply(d$keywords, function(k) if (is.null(k$language) || identical(k$language, lang)) k$label))
  if (is.null(kw)) character() else kw
}

#' Distributions (files, services, pages) of a dataset
#'
#' One row per distribution. The `url` column is the download URL if present, otherwise the
#' access URL. The `kind` column says what each one is: `"file"`, `"service"` (WMS, WFS, APIs,
#' feeds), `"page"` (a web page), `"none"` (no usable URL, e.g. a localhost placeholder) or
#' `"unknown"`.
#' @inheritParams de_get_dataset
#' @param files_only Keep only distributions whose `kind` is `"file"`.
#' @return A data frame with one row per distribution: `id`, `title`, `format`, `media_type`,
#'   `byte_size`, `checksum`, `checksum_algorithm`, `license`, `modified`, `download_url`,
#'   `access_url`, `url` and `kind`. An empty data frame when the dataset has none.
#' @examplesIf interactive()
#' files <- de_distributions("6689f1686e4bd9bc98ed011b", files_only = TRUE)
#' files[, c("title", "format", "kind")]
#' @export
de_distributions <- function(id, lang = "en", files_only = FALSE) {
  df <- de_distribution_table(de_get_dataset(id, raw = TRUE), lang)
  if (files_only && "kind" %in% names(df)) {
    df <- df[df$kind == "file", , drop = FALSE]
    rownames(df) <- NULL
  }
  df
}

# One row per distribution of a raw dataset record; `url` is the download URL, else the access URL.
de_distribution_table <- function(d, lang = "en") {
  rows <- lapply(d$distributions %||% list(), function(x) {
    dl <- chr(x$download_url); ac <- chr(x$access_url)
    cs <- de_checksum(x$checksum)
    data.frame(id = chr(x$id), title = de_pick_lang(x$title, lang), format = chr(x$format$id),
               media_type = chr(x$media_type),
               byte_size = suppressWarnings(as.numeric(chr(x$byte_size))),
               checksum = cs$value, checksum_algorithm = cs$algorithm,
               license = chr(x$license$id), modified = chr(x$modified),
               download_url = dl, access_url = ac, url = if (is.na(dl)) ac else dl,
               kind = de_distribution_kind(x$format$id, x$media_type, if (is.na(dl)) ac else dl, dl),
               stringsAsFactors = FALSE)
  })
  bind_rows_base(rows)
}

# Hash functions that downloads can be checked with. The portal also has a few others (e.g. CRC).
.hashes <- list(md5 = function(con) openssl::md5(con), sha1 = function(con) openssl::sha1(con),
                sha256 = function(con) openssl::sha256(con))
# Hash lengths in hex digits, for checksums that do not name their algorithm.
.hash_by_length <- c("32" = "md5", "40" = "sha1", "64" = "sha256")

# list(algorithm, value) of a distribution's `checksum` field, both lowercase, NA when absent.
# The algorithm is normalised ("SHA-256" and SPDX's "...checksumAlgorithm_sha256" become "sha256").
# When it is not given, a hex value of 32, 40 or 64 digits counts as MD5, SHA-1 or SHA-256;
# otherwise the algorithm is NA.
de_checksum <- function(cs) {
  none <- list(algorithm = NA_character_, value = NA_character_)
  v <- if (is.list(cs)) str1(cs$checksum_value) else NULL
  if (is.null(v) || !nzchar(trimws(v))) return(none)
  value <- tolower(trimws(v))
  a <- str1(cs$algorithm)
  algorithm <- if (!is.null(a) && nzchar(trimws(a))) {
    key <- sub("^.*checksumalgorithm_", "", tolower(trimws(a)))
    gsub("[-_]", "", key)
  } else if (grepl("^[0-9a-f]+$", value)) {
    unname(.hash_by_length[as.character(nchar(value))])
  } else NA_character_
  list(algorithm = algorithm, value = value)
}

# Lowercase hex digest of a file with `algorithm` ("md5", "sha1" or "sha256").
de_file_hash <- function(path, algorithm) paste0(as.character(.hashes[[algorithm]](file(path))))   # paste0 drops the "hash" class

# Check a downloaded file against its checksum. Returns TRUE if checked, FALSE if there was nothing
# to check with (no checksum, or an algorithm other than MD5, SHA-1, SHA-256). On a mismatch,
# deletes the file and stops with an error.
de_verify_checksum <- function(path, algorithm, value) {
  algorithm <- str1(algorithm); value <- str1(value)
  if (is.null(algorithm) || !(algorithm %in% names(.hashes)) || is.null(value) || !nzchar(value))
    return(FALSE)
  got <- de_file_hash(path, algorithm)
  if (got != tolower(value)) {
    unlink(path)
    stop("checksum mismatch: expected ", algorithm, " ", tolower(value), ", got ", got,
         "; the file was deleted (pass verify = FALSE to keep it)", call. = FALSE)
  }
  TRUE
}

# The value to send as If-Range when resuming: a strong ETag, else Last-Modified, else NULL.
# Weak ETags (W/"...") are not allowed in If-Range.
de_range_validator <- function(etag, last_modified) {
  etag <- str1(etag); last_modified <- str1(last_modified)
  if (!is.null(etag) && nzchar(trimws(etag)) && !startsWith(trimws(etag), "W/")) return(trimws(etag))
  if (!is.null(last_modified) && nzchar(trimws(last_modified))) return(trimws(last_modified))
  NULL
}

# What to do with the reply to a request for bytes `offset`- of a partial download: "append" (206
# from `offset`), "replace" (200: the whole file, because the server ignores ranges or the file
# changed), "restart" (416, or a 206 for other bytes: start again without a range) or "error".
de_resume_action <- function(status, content_range, offset) {
  if (status == 206) {
    cr <- str1(content_range)
    m <- if (is.null(cr)) NULL else regmatches(cr, regexec("^\\s*bytes\\s+([0-9]+)-", cr, ignore.case = TRUE))[[1]]
    return(if (length(m) == 2 && as.numeric(m[2]) == offset) "append" else "restart")
  }
  if (status == 200) return("replace")
  if (status == 416) return("restart")
  "error"
}

# Stream `url` into the partial file `part`, continuing an earlier partial download when possible.
# The error raised when a download goes over its size limit (after deleting the partial file).
too_large <- function(url, max_bytes)
  structure(class = c("dataeuropa_too_large", "error", "condition"),
            list(message = paste0(url, " is larger than the limit of ",
                                  format(max_bytes, big.mark = ",", scientific = FALSE),
                                  " bytes; the download was stopped"), call = NULL))

de_fetch_to <- function(url, part, resume = TRUE, max_bytes = NULL) {
  meta <- paste0(part, ".json")
  if (!grepl("^https?://", url, ignore.case = TRUE)) {   # file:// and the like: no ranges
    unlink(meta)
    httr2::req_perform(de_req(url), path = part)
    if (!is.null(max_bytes) && file.size(part) > max_bytes) {
      unlink(part)
      stop(too_large(url, max_bytes))
    }
    return(invisible(part))
  }
  offset <- 0
  req <- httr2::req_headers(de_req(url), `Accept-Encoding` = "identity")   # offsets must refer to the file itself
  if (resume && file.exists(part) && file.exists(meta)) {
    m <- tryCatch(jsonlite::fromJSON(meta), error = function(e) list())
    if (identical(m$url, url) && is.character(m$validator) && file.size(part) > 0) {
      offset <- file.size(part)
      req <- httr2::req_headers(req, Range = paste0("bytes=", format(offset, scientific = FALSE), "-"),
                                `If-Range` = m$validator)
    }
  }
  if (offset == 0) unlink(c(part, meta))
  resp <- httr2::req_perform_connection(httr2::req_error(req, is_error = function(r) FALSE))
  on.exit(close(resp), add = TRUE)
  status <- httr2::resp_status(resp)
  action <- if (offset > 0) de_resume_action(status, httr2::resp_header(resp, "content-range"), offset) else "replace"
  if (action == "restart") {
    unlink(c(part, meta))
    return(de_fetch_to(url, part, resume = FALSE, max_bytes = max_bytes))
  }
  if (action == "error" || status >= 400)
    stop("HTTP ", status, " from ", url, call. = FALSE)
  if (action == "replace") {
    v <- de_range_validator(httr2::resp_header(resp, "etag"), httr2::resp_header(resp, "last-modified"))
    if (is.null(v)) unlink(meta) else writeLines(jsonlite::toJSON(list(url = url, validator = v), auto_unbox = TRUE), meta)
  }
  start <- if (action == "append") offset else 0
  announced <- suppressWarnings(as.numeric(httr2::resp_header(resp, "content-length") %||% NA))
  if (!is.null(max_bytes) && !is.na(announced) && start + announced > max_bytes) {
    unlink(c(part, meta))
    stop(too_large(url, max_bytes))
  }
  con <- file(part, if (action == "append") "ab" else "wb")
  on.exit(close(con), add = TRUE)
  size <- start
  while (!httr2::resp_stream_is_complete(resp)) {
    piece <- httr2::resp_stream_raw(resp, kb = 1024)
    size <- size + length(piece)
    if (!is.null(max_bytes) && size > max_bytes) {
      close(con)
      on.exit(close(resp))
      unlink(c(part, meta))
      stop(too_large(url, max_bytes))
    }
    writeBin(piece, con)
  }
  close(con)
  on.exit(close(resp))
  unlink(meta)
  invisible(part)
}

#' Download a distribution to disk
#'
#' If the row has a checksum (`checksum` and `checksum_algorithm`; MD5, SHA-1 or SHA-256), the
#' file is checked against it. On a mismatch the file is deleted and an error is raised;
#' `verify = FALSE` skips the check. `byte_size` is not checked: on the portal it is often a
#' placeholder (0, 1, 1024).
#'
#' The file is written as `<file>.part` and renamed when complete. If a download is interrupted,
#' calling `de_download()` again for the same URL and destination continues where it stopped, when
#' the server supports ranges and identifies the file (ETag or Last-Modified); a file that changed
#' meanwhile is downloaded again from the start. `resume = FALSE` always starts from the start.
#'
#' @param x A URL, or a one-row data frame from [de_distributions()].
#' @param dest A file path, or an existing directory to save the file in under its own name.
#'   Required: nothing is written to the working directory unless you pass it (e.g. `"."`).
#' @param verify Check the file against the row's checksum, if it has one.
#' @param resume Continue an interrupted download of the same URL to the same place.
#' @param max_bytes Stop a download that is (or is announced as) larger than this, delete the
#'   partial file and raise an error. Default: no limit.
#' @return The local path, invisibly.
#' @examplesIf interactive()
#' files <- de_distributions("6689f1686e4bd9bc98ed011b", files_only = TRUE)
#' path <- de_download(files[files$title == "QA_2024_Q1", ], tempdir())
#' file.size(path)
#' @export
de_download <- function(x, dest, verify = TRUE, resume = TRUE, max_bytes = NULL) {
  if (missing(dest))
    stop("de_download() needs a destination: a file path or a directory, e.g. de_download(x, tempdir())",
         call. = FALSE)
  url <- if (is.character(x)) x else str1(x$url)
  if (is.null(url) || !nzchar(url)) stop("no URL available for this distribution", call. = FALSE)
  name <- utils::URLdecode(basename(sub("[?#].*$", "", url)))
  if (!nzchar(name)) name <- "download"
  path <- if (dir.exists(dest)) file.path(dest, name) else dest
  de_fetch_to(url, paste0(path, ".part"), resume = resume, max_bytes = max_bytes)
  file.rename(paste0(path, ".part"), path)
  if (verify && !is.character(x)) de_verify_checksum(path, x$checksum_algorithm, x$checksum)
  invisible(path)
}

# ---------------------------------------------------------------- load into a table

# Format ids, media types and file extensions that map to a readable file format.
# Keys are matched after de_format_key(): lowercase, look-alike letters folded, leading dot removed.
.file_formats <- c(
  "csv" = "csv", "text/csv" = "csv", "csv/utf8" = "csv", "comma separated value (csv)" = "csv",
  "tsv" = "csv", "text/tab-separated-values" = "csv",   # the CSV reader detects the tab delimiter
  "json" = "json", "application/json" = "json",
  "xlsx" = "xlsx", "xlsm" = "xlsx", "excel (.xlsx)" = "xlsx",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" = "xlsx",
  "vnd.openxmlformats-officedocument.spreadsheetml.sheet" = "xlsx",
  "parquet" = "parquet", "application/vnd.apache.parquet" = "parquet", "application/x-parquet" = "parquet")
# Media types and extensions of compressed archives, which must be unpacked before reading.
.archives <- c("application/zip", "application/x-zip-compressed", "application/gzip", "application/x-gzip",
               "application/x-tar", "zip", "gz", "tgz", "tar")
# Format ids of services (map servers, APIs) rather than files. Ids ending in "_srvc" count too.
# Atom and RSS feeds count as services: in INSPIRE they list files rather than being one.
.service_formats <- c("wms", "wfs", "wcs", "wmts", "ogc:wms", "ogc:wfs", "ogc:wcs", "ogc:wmts", "ogc:ows-c",
                      "api", "open-api", "ogc api features", "ogcapi-features", "ogcfeat",
                      "arcgis geoservices rest api", "rest", "esri rest", "application/vnd.ogc.wms_xml",
                      "sparql", "sparqlq", "inspire download service", "atom", "rss", "application/atom+xml",
                      "application/rss+xml")
# Format ids and media types of web pages (landing pages, links, viewers) rather than files.
.page_formats <- c("html", "text/html", "application/xhtml+xml", "web page", "html_simpl", "www:link",
                   "www:link-1.0-http--link", "www:link-1.0-http--metadata-url", "url", "view", "doi", "map_prvw")
# Format ids that say nothing about the content ("onLine" is ISO 19115 for "a link").
.no_format <- c("online", "other", "inconnu", "unknown", "n/a")
# Hosts that only appear in placeholder URLs.
.placeholder_hosts <- c("localhost", "127.0.0.1", "0.0.0.0", "::1", "")

# A format id, media type or extension as matched against the tables above: look-alike letters
# some publishers type (Cyrillic a e o p c x, both cases) folded, lowercase, leading dot removed.
de_format_key <- function(value) {
  key <- tolower(chartr("\u0430\u0435\u043e\u0440\u0441\u0445\u0410\u0415\u041e\u0420\u0421\u0425",
                        "aeopcxAEOPCX", enc2utf8(trimws(value))))
  if (startsWith(key, "file:///")) key <- sub("^.*/", "", key)
  sub("^\\.+", "", key)
}

# The file extension of a URL's last path part, without query or fragment; NULL if none.
de_url_extension <- function(url) {
  if (is.null(url) || !nzchar(url)) return(NULL)
  last <- sub("^.*/", "", sub("/+$", "", sub("[?#].*$", "", url)))
  if (grepl(".", last, fixed = TRUE)) sub("^.*\\.", "", last) else NULL
}

has_text <- function(x) !is.null(x) && nzchar(trimws(x))

str1 <- function(x) if (is.null(x) || length(x) == 0 || (is.atomic(x) && is.na(x[[1]]))) NULL else as.character(x[[1]])

# "csv", "json", "xlsx", "parquet", "service", "archive", "page" or NA (unknown). A compressed media
# type or extension means "archive" whatever the format id says; otherwise the first of format id,
# media type, file extension recognised as a service or readable file wins. "page" only when one
# of them says so and none names a service or a file.
de_file_format <- function(fmt = NULL, media_type = NULL, url = NULL) {
  fmt <- str1(fmt); media_type <- str1(media_type); url <- str1(url)
  ext <- de_url_extension(url)
  for (cand in list(media_type, ext))
    if (!is.null(cand) && de_format_key(cand) %in% .archives) return("archive")
  keys <- vapply(Filter(has_text, list(fmt, media_type, ext)), de_format_key, "")
  for (key in keys) {
    if (key %in% .service_formats || endsWith(key, "_srvc")) return("service")
    if (key %in% names(.file_formats)) return(unname(.file_formats[key]))
  }
  if (any(keys %in% .page_formats)) "page" else NA_character_
}

# What a distribution is: "file", "service", "page", "none" (no usable URL) or "unknown".
# "none": no URL, a scheme other than http(s) or ftp, or a placeholder host (localhost).
# "service": an OGC query in the URL (service=WMS, request=GetCapabilities), or a service format.
# "page": a web-page format, or no format and an .html URL. "file": any other format or media
# type, or a download URL. Otherwise "unknown". Format ids that say nothing (onLine, OTHER) count
# as no format.
de_distribution_kind <- function(fmt = NULL, media_type = NULL, url = NULL, download_url = NULL) {
  fmt <- str1(fmt); media_type <- str1(media_type); url <- str1(url); download_url <- str1(download_url)
  if (!has_text(url)) return("none")
  u <- trimws(url)
  m <- regmatches(u, regexec("^([A-Za-z][A-Za-z0-9+.-]*)://(?:[^@/?#]*@)?(\\[[^]]*\\]|[^:/?#]*)", u, perl = TRUE))[[1]]
  if (length(m) != 3) return("none")
  host <- tolower(gsub("^\\[|\\]$", "", m[3]))
  if (!(tolower(m[2]) %in% c("http", "https", "ftp")) || host %in% .placeholder_hosts) return("none")
  query <- if (grepl("?", u, fixed = TRUE)) sub("#.*$", "", sub("^[^?]*\\?", "", u)) else ""
  if (grepl("(^|&)(service=(wms|wfs|wcs|wmts|csw|wps|sos)|request=getcapabilities)(&|$)", query, ignore.case = TRUE))
    return("service")
  f <- de_file_format(fmt, media_type, url)
  if (f %in% c("service", "page")) return(f)
  informative <- function(v) has_text(v) && !(de_format_key(v) %in% .no_format)
  if (!is.na(f) || informative(fmt) || informative(media_type)) return("file")
  if (tolower(de_url_extension(url) %||% "") %in% c("html", "htm")) return("page")
  if (has_text(download_url)) "file" else "unknown"
}

# Refuse a downloaded file that is an archive or an HTML page rather than data.
de_check_payload <- function(path) {
  head <- readBin(path, "raw", 512)
  if ((length(head) >= 4 && identical(head[1:4], as.raw(c(0x50, 0x4b, 0x03, 0x04)))) ||
      (length(head) >= 2 && identical(head[1:2], as.raw(c(0x1f, 0x8b)))))
    stop("the download is a compressed archive (ZIP or gzip); use de_download() and unpack it", call. = FALSE)
  de_check_html(head)
}

# Refuse a download whose first bytes `head` are an HTML page.
de_check_html <- function(head) {
  skip <- as.raw(c(0xef, 0xbb, 0xbf, 0x20, 0x09, 0x0d, 0x0a))   # byte-order mark and leading whitespace
  first <- which(!(head %in% skip))[1]
  rest <- if (is.na(first)) integer() else as.integer(head[first:min(length(head), first + 19)])
  upper <- rest >= 65L & rest <= 90L
  rest[upper] <- rest[upper] + 32L                               # ASCII lowercase, on bytes: binary
  starts <- function(prefix) {                                   # files are not valid text
    p <- as.integer(charToRaw(prefix))
    length(rest) >= length(p) && all(rest[seq_along(p)] == p)
  }
  if (starts("<!doctype html") || starts("<html"))
    stop("the download is an HTML page, not a data file (often a landing page)", call. = FALSE)
  invisible(NULL)
}

# UTF-8 (with or without a byte-order mark), falling back to Latin-1.
de_decode <- function(raw) {
  if (length(raw) >= 3 && identical(raw[1:3], as.raw(c(0xef, 0xbb, 0xbf)))) raw <- raw[-(1:3)]
  text <- rawToChar(raw)
  if (validUTF8(text)) { Encoding(text) <- "UTF-8"; text } else iconv(text, from = "latin1", to = "UTF-8")
}

# The most frequent of , ; tab | in the header line (comma on a tie or if none occurs).
de_sniff_delimiter <- function(text) {
  header <- sub("\n.*$", "", text)
  delims <- c(",", ";", "\t", "|")
  counts <- vapply(delims, function(d) lengths(regmatches(header, gregexpr(d, header, fixed = TRUE))), 0L)
  best <- max(counts)
  if (best == 0 || counts[[1]] == best) return(",")
  delims[-1][which(counts[-1] == best)[1]]
}

# An array of objects, or an object holding exactly one array of objects.
de_json_records <- function(data) {
  is_obj <- function(r) is.list(r) && (length(r) == 0 || !is.null(names(r)))
  if (is.list(data) && is.null(names(data)) && all(vapply(data, is_obj, TRUE))) return(data)
  if (is.list(data) && !is.null(names(data))) {
    lists <- Filter(function(v) is.list(v) && length(v) > 0 && is.null(names(v)) && all(vapply(v, is_obj, TRUE)), data)
    if (length(lists) == 1) return(lists[[1]])
  }
  stop("JSON is not a table: expected an array of objects, or an object holding one", call. = FALSE)
}

# One JSON column: numbers, logicals or strings become an atomic vector; anything else a list.
json_column <- function(vals) {
  present <- Filter(Negate(is.null), vals)
  atomic1 <- function(v) is.atomic(v) && length(v) == 1
  if (length(present) > 0 && all(vapply(present, atomic1, TRUE))) {
    fill <- function(conv, na) vapply(vals, function(v) if (is.null(v)) na else conv(v), na)
    if (all(vapply(present, is.logical, TRUE))) return(fill(as.logical, NA))
    if (all(vapply(present, is.numeric, TRUE))) return(fill(as.numeric, NA_real_))
    if (all(vapply(present, is.character, TRUE))) return(fill(as.character, NA_character_))
  }
  if (length(present) == 0) return(rep(NA, length(vals)))
  I(lapply(vals, function(v) if (is.null(v)) NA else v))
}

# Read a local file of format `fmt` into a data frame.
de_read_table <- function(path, fmt, sheet = NULL) {
  if (fmt == "csv") {
    text <- de_decode(readBin(path, "raw", file.info(path)$size))
    df <- utils::read.csv(text = text, sep = de_sniff_delimiter(text), na.strings = "",
                          check.names = FALSE, stringsAsFactors = FALSE, encoding = "UTF-8")
    bool_words <- c("true", "True", "TRUE", "false", "False", "FALSE")
    for (col in names(df)) {
      v <- df[[col]]
      if (is.character(v) && any(!is.na(v)) && all(is.na(v) | v %in% bool_words))
        df[[col]] <- tolower(v) == "true"   # lowercase true/false, which read.csv leaves as text
    }
    return(df)
  }
  if (fmt == "json") {
    records <- de_json_records(jsonlite::fromJSON(de_decode(readBin(path, "raw", file.info(path)$size)),
                                                  simplifyVector = FALSE))
    cols <- unique(unlist(lapply(records, names)))
    out <- lapply(cols, function(c) json_column(lapply(records, function(r) r[[c]])))
    names(out) <- cols
    return(as.data.frame(out, check.names = FALSE, stringsAsFactors = FALSE))
  }
  if (fmt == "xlsx") {
    if (!requireNamespace("readxl", quietly = TRUE))
      stop("reading XLSX needs the readxl package: install.packages(\"readxl\")", call. = FALSE)
    return(as.data.frame(readxl::read_excel(path, sheet = sheet %||% 1)))
  }
  if (fmt == "parquet") {
    if (!requireNamespace("arrow", quietly = TRUE))
      stop("reading Parquet needs the arrow package: install.packages(\"arrow\")", call. = FALSE)
    return(as.data.frame(arrow::read_parquet(path)))
  }
  stop("unsupported format '", fmt, "'", call. = FALSE)
}

#' Download a distribution and read it into a data frame
#'
#' Reads CSV and JSON; XLSX with the readxl package and Parquet with the arrow package (both
#' optional). The format comes from `format` if given (`"csv"`, `"json"`, `"xlsx"`, `"parquet"`),
#' else from the row's format id, its media type, then the URL's file extension.
#'
#' CSV: the delimiter (`,` `;` tab `|`) is taken from the header line, text is read as UTF-8 with
#' a Latin-1 fallback, only empty cells count as missing, and dates stay text. JSON: an array of
#' objects, or an object holding exactly one such array; keys become columns.
#'
#' Stops with an error for services (WMS, WFS, APIs), compressed archives, HTML pages served
#' instead of data, formats it cannot tell or read, and files that fail their checksum (see
#' [de_download()]).
#'
#' @param x A URL, or a one-row data frame from [de_distributions()].
#' @param format Override the detected format: "csv", "json", "xlsx" or "parquet".
#' @param sheet XLSX sheet name or 1-based index (default: the first sheet).
#' @return A data frame.
#' @examplesIf interactive()
#' files <- de_distributions("6689f1686e4bd9bc98ed011b", files_only = TRUE)
#' qa <- de_load_distribution(files[files$title == "QA_2024_Q1", ])
#' head(qa)
#' @export
de_load_distribution <- function(x, format = NULL, sheet = NULL) {
  row <- if (is.character(x)) list(url = x) else x
  url <- str1(row$url)
  if (is.null(url) || !nzchar(url)) stop("no URL available for this distribution", call. = FALSE)
  if (!is.null(format)) {
    fmt <- de_file_format(format)
    if (is.na(fmt) || fmt %in% c("service", "archive", "page"))
      stop("format must be one of csv, json, xlsx, parquet (got '", format, "')", call. = FALSE)
  } else {
    fmt <- de_file_format(row$format, row$media_type, url)
  }
  if (identical(fmt, "service"))
    stop(url, " is a service, not a file; open it with a client for that service", call. = FALSE)
  if (identical(fmt, "archive"))
    stop(url, " is a compressed archive; use de_download() and unpack it", call. = FALSE)
  if (identical(fmt, "page"))
    stop(url, " is a web page, not a file", call. = FALSE)
  if (is.na(fmt))
    stop("cannot tell the file format of ", url, "; pass format = \"csv\", \"json\", \"xlsx\" or \"parquet\"",
         call. = FALSE)
  tmp <- tempfile("dataeuropa")
  dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  path <- de_download(x, file.path(tmp, paste0("distribution.", fmt)))
  if (fmt %in% c("csv", "json")) de_check_payload(path)
  de_read_table(path, fmt, sheet)
}

# ---------------------------------------------------------------- geodata

# Format ids, media types and extensions of vector geodata files, after de_format_key(). Values
# are the file extension the download is saved under (GDAL needs it for some formats); "zip" for
# formats published as ZIP archives (shapefiles, MapInfo, file geodatabases).
.geo_formats <- c(
  "geojson" = "geojson", "application/geo+json" = "geojson", "geo+json" = "geojson",
  "application/vnd.geo+json" = "geojson",
  "kml" = "kml", "application/vnd.google-earth.kml+xml" = "kml", "vnd.google-earth.kml+xml" = "kml",
  "kmz" = "kmz", "application/vnd.google-earth.kmz" = "kmz", "vnd.google-earth.kmz" = "kmz",
  "gml" = "gml", "application/gml+xml" = "gml", "gml+xml" = "gml", "geographic markup language (gml)" = "gml",
  "xplangml" = "gml", "kuntagml" = "gml",
  "gpkg" = "gpkg", "geopackage" = "gpkg", "geopackage - gpkg" = "gpkg", "application/geopackage+sqlite3" = "gpkg",
  "geopackage+sqlite3" = "gpkg",
  "gpx" = "gpx", "application/gpx+xml" = "gpx", "gpx+xml" = "gpx",
  "fgb" = "fgb", "flatgeobuf" = "fgb",
  "shp" = "zip", "shape" = "zip", "shapefile" = "zip", "shapefiles" = "zip", "shapefile (zip)" = "zip",
  "shapefile zip" = "zip", "shp / zip" = "zip", "esri shape" = "zip", "esri shapefile" = "zip",
  "esri shapefile (shp)" = "zip", "www:download:esri shapefile" = "zip",
  "tab" = "zip", "mapinfo tab" = "zip", "gdb" = "zip", "esri file geodatabase" = "zip", "file geodatabase" = "zip")
# Extensions of the files GDAL is asked to open inside an archive; a ".gdb" folder counts too.
.geo_member_exts <- c("shp", "gpkg", "geojson", "kml", "gml", "gpx", "tab", "fgb")
.nested_archive_exts <- c("zip", "kmz", "gz", "tgz", "tar", "7z", "rar")

# The extension to save a geodata download under ("geojson", "kml", "kmz", "gml", "gpkg", "gpx",
# "fgb", or "zip" for shapefiles, MapInfo and file geodatabases), from the format id, then the
# media type, then the URL's extension. NA if none of them names a geodata format.
de_geo_format <- function(fmt = NULL, media_type = NULL, url = NULL) {
  for (cand in list(str1(fmt), str1(media_type), de_url_extension(str1(url)))) {
    if (!has_text(cand)) next
    key <- de_format_key(cand)
    if (key %in% names(.geo_formats)) return(unname(.geo_formats[key]))
  }
  NA_character_
}

# The lowercase extension of the last part of each path, "" if none.
path_ext <- function(paths) {
  base <- sub("^.*/", "", paths)
  ifelse(grepl(".", base, fixed = TRUE), tolower(sub("^.*\\.", "", base)), "")
}

# Choose the file to read inside an archive, from its member `names`. Candidates: files ending in
# .shp, .gpkg, .geojson, .kml, .gml, .gpx, .tab or .fgb, and .gdb folders; macOS metadata is
# ignored. One candidate: that one. Several: the one whose name (without extension) or path equals
# `layer`, ignoring case; `layer` is then used up. Returns list(member, layer left for reading).
de_geo_member <- function(names, layer = NULL) {
  names <- as.character(unlist(names))
  files <- gsub("\\\\", "/", names[!grepl("[/\\\\]$", names)])
  files <- files[!startsWith(files, "__MACOSX/") & !startsWith(sub("^.*/", "", files), "._")]
  cands <- character()
  for (n in files) {
    pos <- regexpr(".gdb/", tolower(n), fixed = TRUE)
    if (pos > 0) {
      folder <- substr(n, 1, pos + 3)
      if (!(folder %in% cands)) cands <- c(cands, folder)
    } else if (path_ext(n) %in% .geo_member_exts) {
      cands <- c(cands, n)
    }
  }
  cands <- sort(cands, method = "radix")
  if (!length(cands)) {
    nested <- sort(files[path_ext(files) %in% .nested_archive_exts], method = "radix")
    if (length(nested))
      stop("the archive holds other archives (", paste(nested, collapse = ", "),
           "); de_download() it and unpack them", call. = FALSE)
    stop("the archive holds no geodata file (looked for .shp, .gpkg, .geojson, .kml, .gml, .gpx, .tab, ",
         ".fgb files and .gdb folders)", call. = FALSE)
  }
  if (length(cands) == 1) return(list(member = cands, layer = layer))
  if (is.character(layer) && length(layer) == 1) {
    want <- tolower(layer)
    stems <- tolower(sub("\\.[^.]*$", "", sub("^.*/", "", cands)))
    hits <- cands[tolower(cands) == want | stems == want]
    if (length(hits) == 1) return(list(member = hits, layer = NULL))
  }
  stop("the archive holds ", length(cands), " geodata files (", paste(cands, collapse = ", "),
       "); pick one with layer =", call. = FALSE)
}

# Format ids of the feature services de_load_geodata() reads, after de_format_key().
.wfs_formats <- c("wfs", "ogc:wfs", "wfs_srvc")
.oapif_formats <- c("ogcfeat", "ogc api features", "ogcapi-features")

# The GDAL data source for a feature service: "WFS:<url>" or "OAPIF:<url>", or NA when the
# distribution is not one (or is another service, such as WMS). A `service=` parameter in the URL
# decides (service=WFS: WFS, anything else: NA), because format ids are often wrong. Otherwise an
# OGC API Features format id, or a URL ending in /collections/{id} or /collections/{id}/items,
# means OGC API Features (the URL is cut to the collection, without query); a WFS format id
# means WFS. Only http(s) URLs.
de_service_source <- function(fmt = NULL, url = NULL) {
  fmt <- str1(fmt); url <- str1(url)
  if (!has_text(url)) return(NA_character_)
  u <- trimws(url)
  m <- regmatches(u, regexec("^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]+)([^?#]*)(\\?[^#]*)?", u))[[1]]
  if (length(m) == 0 || !(tolower(m[2]) %in% c("http", "https"))) return(NA_character_)
  query <- sub("^\\?", "", m[5])
  path <- sub("/+$", "", m[4])
  svc <- regmatches(query, regexec("(?:^|&)service=([^&]*)", query, ignore.case = TRUE, perl = TRUE))[[1]]
  if (length(svc)) return(if (tolower(svc[2]) == "wfs") paste0("WFS:", u) else NA_character_)
  key <- if (has_text(fmt)) de_format_key(fmt) else ""
  coll <- regmatches(path, regexec("/collections/[^/]+(/items)?$", path))[[1]]
  if (key %in% .oapif_formats || length(coll)) {
    if (length(coll) && nzchar(coll[2])) path <- sub("/items$", "", path)
    return(paste0("OAPIF:", tolower(m[2]), "://", m[3], path))
  }
  if (key %in% .wfs_formats) paste0("WFS:", u) else NA_character_
}

# The layer to read: `layer` by name (exact, else ignoring case, else once without a namespace
# prefix, as in WFS names: "roads" for "ns:roads") or 1-based position; by default
# the first, with a message if there are more.
de_pick_layer <- function(layers, layer = NULL, what = "the file") {
  if (!length(layers)) stop(what, " holds no layers", call. = FALSE)
  all <- paste(layers, collapse = ", ")
  if (is.null(layer)) {
    if (length(layers) > 1)
      message(what, " has ", length(layers), " layers (", all, "); reading '", layers[1],
              "', pick another with layer =")
    return(layers[1])
  }
  if (is.numeric(layer)) {
    if (length(layer) == 1 && layer == round(layer) && layer >= 1 && layer <= length(layers)) return(layers[layer])
    stop("layer ", layer, " is out of range: ", what, " has ", length(layers), " layers (", all, ")", call. = FALSE)
  }
  if (layer %in% layers) return(layer)
  want <- tolower(layer)
  hits <- layers[tolower(layers) == want]
  if (length(hits) == 1) return(hits)
  hits <- layers[sub("^.*:", "", tolower(layers)) == want]   # without a namespace prefix ("ns:roads")
  if (length(hits) == 1) return(hits)
  stop("no layer '", layer, "'; ", what, " has ", all, call. = FALSE)
}

# Read a local geodata file (or a ZIP holding one) into an sf data frame.
de_read_geodata <- function(path, layer = NULL, crs = NULL) {
  if (!requireNamespace("sf", quietly = TRUE))
    stop("de_load_geodata() needs the sf package: install.packages(\"sf\")", call. = FALSE)
  head <- readBin(path, "raw", 512)
  de_check_html(head)
  src <- normalizePath(path, winslash = "/")
  if (length(head) >= 4 && identical(head[1:4], as.raw(c(0x50, 0x4b, 0x03, 0x04)))) {
    pick <- de_geo_member(utils::unzip(path, list = TRUE)$Name, layer)
    src <- paste0("/vsizip/", src, "/", pick$member)
    layer <- pick$layer
  } else if (length(head) >= 2 && identical(head[1:2], as.raw(c(0x1f, 0x8b)))) {
    src <- paste0("/vsigzip/", src)
  }
  de_read_source(src, layer, crs)
}

# Read a GDAL data source (a local path, /vsizip/ path, or WFS:/OAPIF: service) into an sf data
# frame. `max_features`: read at most that many (with OGR SQL LIMIT), with a warning if there are more.
de_read_source <- function(src, layer = NULL, crs = NULL, max_features = NULL, what = "the file") {
  layers <- tryCatch(suppressWarnings(sf::st_layers(src)$name),
                     error = function(e) stop("cannot read ", what, " as geodata: ", conditionMessage(e), call. = FALSE))
  name <- de_pick_layer(layers, layer, what)
  quiet_read <- function(...) withCallingHandlers(
    sf::st_read(src, ..., quiet = TRUE, stringsAsFactors = FALSE),
    warning = function(w) if (grepl("no simple feature geometries", conditionMessage(w))) invokeRestart("muffleWarning"))
  df <- tryCatch(
    if (is.null(max_features)) quiet_read(layer = name)
    else quiet_read(query = sprintf('SELECT * FROM "%s" LIMIT %s', gsub('"', '""', name),
                                    format(max_features + 1, scientific = FALSE))),
    error = function(e) if (what == "the file") stop(e) else
      stop("cannot read ", what, ": ", conditionMessage(e), call. = FALSE))
  if (!is.null(max_features) && nrow(df) > max_features) {
    n <- format(max_features, big.mark = ",", scientific = FALSE)
    warning(what, " has more than ", n, " features; read the first ", n, " (pass max_features = Inf for all)",
            call. = FALSE)
    df <- df[seq_len(max_features), ]
  }
  if (!inherits(df, "sf")) stop(what, " has no geometries (a plain table?); use de_load_distribution()", call. = FALSE)
  if (attr(df, "sf_column") != "geometry") sf::st_geometry(df) <- "geometry"
  if (is.na(sf::st_crs(df))) {
    if (!is.null(crs))
      stop("the data has no coordinate reference system (no .prj file?), so it cannot be reprojected; ",
           "read it without crs and set one with sf::st_set_crs()", call. = FALSE)
    warning("the data has no coordinate reference system (no .prj file?); coordinates are as stored", call. = FALSE)
  } else if (!is.null(crs)) {
    df <- sf::st_transform(df, crs)
  }
  df
}

# 2D geometry type names, as GEOS and the Python reference spell them.
.geometry_types <- c(POINT = "Point", LINESTRING = "LineString", POLYGON = "Polygon", MULTIPOINT = "MultiPoint",
                     MULTILINESTRING = "MultiLineString", MULTIPOLYGON = "MultiPolygon",
                     GEOMETRYCOLLECTION = "GeometryCollection")

# What the conformance cases compare of an sf data frame: attribute columns (or the values of
# `columns` only), row count (nrow), 2D geometry types, EPSG code and bounds.
de_geo_summary <- function(df, columns = NULL) {
  plain <- sf::st_drop_geometry(df)
  attrs <- names(plain)
  out <- list()
  if (is.null(columns)) out$columns <- as.list(attrs)
  cols <- if (is.null(columns)) attrs else as.character(unlist(columns))
  out$values <- stats::setNames(lapply(cols, function(col) as.list(plain[[col]])), cols)
  out$nrow <- nrow(df)
  types <- unique(as.character(sf::st_geometry_type(df)))
  types <- ifelse(types %in% names(.geometry_types), .geometry_types[types], types)
  out$geometry_types <- as.list(sort(unique(unname(types)), method = "radix"))
  epsg <- sf::st_crs(df)$epsg
  out["crs"] <- list(if (is.null(epsg) || is.na(epsg)) NULL else epsg)
  out$bounds <- as.list(round(unname(as.numeric(sf::st_bbox(df))), 6))
  out
}

#' Download a geodata distribution, or read a feature service, into an sf data frame
#'
#' Needs the sf package. GDAL does the reading, so any vector format it knows works: GeoJSON,
#' Shapefile, GeoPackage, KML/KMZ, GML, GPX, MapInfo TAB, FlatGeobuf, file geodatabase. The
#' geometry column is always called `geometry`.
#'
#' ZIP archives (how shapefiles are published) are opened in place. Inside, the one geodata file is
#' read (a .shp with its .dbf/.shx/.prj, .gpkg, .geojson, .kml, .gml, .gpx, .tab, .fgb, or a .gdb
#' folder); if there are several, `layer` picks one by file name (without extension), otherwise an
#' error lists them. Archives inside archives are not opened.
#'
#' The source coordinate reference system is kept; a file without one (a shapefile without .prj)
#' is read as stored, with a warning.
#'
#' Feature services are read too: WFS (`service=WFS` URLs, WFS format ids) and OGC API Features
#' (collection or landing-page URLs, OGCFEAT format ids). GDAL pages through the results. Each
#' collection or feature type is a layer.
#'
#' Raises an error for other services (WMS, ...), web pages, HTML served instead of data, files or
#' services GDAL cannot read, and checksum mismatches.
#' @param x A URL, or a one-row data frame from [de_distributions()].
#' @param layer A layer by name or 1-based position, in files with several (GeoPackage, file
#'   geodatabase). Default: the first, with a message if there are more.
#' @param crs Reproject to this coordinate reference system, e.g. `"EPSG:4326"`.
#' @param max_mb Do not download files larger than this many megabytes; `Inf` lifts the limit.
#' @param max_features Read at most this many features from a service, with a warning when there
#'   are more; `Inf` reads all.
#' @return An sf data frame.
#' @examplesIf interactive() && requireNamespace("sf", quietly = TRUE)
#' dists <- de_distributions("eac1e504-9d63-4670-95b3-3ef04e22aa6e~~1")
#' districts <- de_load_geodata(dists[dists$format == "OGCFEAT", ])
#' sf::st_crs(districts)$epsg
#' @export
de_load_geodata <- function(x, layer = NULL, crs = NULL, max_mb = 200, max_features = 10000) {
  if (!requireNamespace("sf", quietly = TRUE))
    stop("de_load_geodata() needs the sf package: install.packages(\"sf\")", call. = FALSE)
  row <- if (is.character(x)) list(url = x) else x
  url <- str1(row$url)
  if (is.null(url) || !nzchar(url)) stop("no URL available for this distribution", call. = FALSE)
  source <- de_service_source(row$format, url)
  if (!is.na(source)) {
    limit <- if (is.null(max_features) || is.infinite(max_features)) NULL else max_features
    return(de_read_source(source, layer, crs, max_features = limit, what = "the service"))
  }
  kind <- de_distribution_kind(row$format, row$media_type, url, row$download_url)
  if (kind == "service")
    stop(url, " is a service (", str1(row$format) %||% "", ") that de_load_geodata() cannot read; ",
         "it reads files, WFS and OGC API Features", call. = FALSE)
  if (kind == "page") stop(url, " is a web page, not a file", call. = FALSE)
  ext <- de_geo_format(row$format, row$media_type, url)
  if (is.na(ext)) ext <- de_url_extension(url) %||% ""
  if (!grepl("^[A-Za-z0-9]{1,8}$", ext)) ext <- "dat"
  tmp <- tempfile("dataeuropa")
  dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  limit <- if (is.null(max_mb) || is.infinite(max_mb)) NULL else max_mb * 1e6
  path <- tryCatch(de_download(x, file.path(tmp, paste0("distribution.", tolower(ext))), max_bytes = limit),
                   dataeuropa_too_large = function(e)
                     stop(url, " is larger than ", format(max_mb, scientific = FALSE),
                          " MB; pass max_mb = Inf to load it anyway", call. = FALSE))
  de_read_geodata(path, layer, crs)
}

#' Values and counts of a facet
#'
#' @param facet e.g. "country", "format", "categories", "catalog", "publisher".
#' @param top Keep the `top` most frequent values (NULL for all).
#' @inheritParams de_search_datasets
#' @return A data frame with columns `id`, `label` and `count`, most frequent first.
#' @examplesIf interactive()
#' de_facet_values("format", country = "pt", top = 10)
#' @export
de_facet_values <- function(facet, q = NULL, top = 50, ...) {
  fid <- if (facet %in% names(.facet_aliases)) unname(.facet_aliases[facet]) else facet
  res <- de_search(q, limit = 0, aggregation = TRUE,
                   extra = list(aggregationAllFields = "false", aggregationFields = fid), ...)
  df <- de_facet_table(res, fid, top)
  if (is.null(df)) stop("unknown facet '", facet, "'")
  df
}

# Rows (id, label, count) of facet `fid` in a search result, most frequent first; NULL if absent.
# `label` is the item's title, else its label, else its id; a missing count is 0. Ties keep the
# API's order.
de_facet_table <- function(res, fid, top = NULL) {
  for (f in res$facets) if (identical(f$id, fid)) {
    rows <- lapply(f$items, function(i) {
      label <- de_pick_lang(i$title)
      if (is.na(label) || !nzchar(label)) label <- chr(i$label)
      if (is.na(label) || !nzchar(label)) label <- chr(i$id)
      data.frame(id = chr(i$id), label = label, count = as.numeric(i$count %||% 0), stringsAsFactors = FALSE)
    })
    df <- bind_rows_base(rows)
    if (nrow(df) == 0) return(data.frame(id = character(), label = character(), count = numeric()))
    df <- df[order(-df$count), , drop = FALSE]
    rownames(df) <- NULL
    return(if (is.null(top)) df else utils::head(df, top))
  }
  NULL
}

#' Ids of all harvested catalogues
#' @return A character vector of catalogue ids.
#' @examplesIf interactive()
#' head(de_catalogues())
#' @export
de_catalogues <- function() unlist(de_get_json(paste0(SEARCH_URL, "/catalogues"), cacheable = TRUE))

#' Dataset metadata as RDF text
#' @param id Dataset id.
#' @param fmt "ttl" (Turtle) or "jsonld".
#' @return The RDF document as a single string.
#' @examplesIf interactive()
#' ttl <- de_get_rdf("6689f1686e4bd9bc98ed011b")
#' cat(substr(ttl, 1, 500))
#' @export
de_get_rdf <- function(id, fmt = c("ttl", "jsonld")) {
  fmt <- match.arg(fmt)
  httr2::resp_body_string(httr2::req_perform(de_req(paste0(REPO_URL, "/datasets/", id, ".", fmt))))
}

#' Run a SPARQL query against data.europa.eu
#'
#' @param query SPARQL SELECT or ASK text.
#' @return A data frame of plain string values (SELECT) or a logical (ASK).
#' @examplesIf interactive()
#' de_sparql("SELECT ?d WHERE { ?d a <http://www.w3.org/ns/dcat#Dataset> } LIMIT 3")
#' @export
de_sparql <- function(query) {
  req <- de_req(SPARQL_URL) |>
    httr2::req_headers(Accept = "application/sparql-results+json") |>
    httr2::req_body_form(query = query)
  de_sparql_table(de_json(httr2::req_perform(req)))
}

# ASK result as a logical, or SELECT bindings as a data frame of plain strings (NA when unbound).
de_sparql_table <- function(j) {
  if (!is.null(j$boolean)) return(isTRUE(j$boolean))
  cols <- unlist(j$head$vars)
  rows <- lapply(j$results$bindings, function(b) {
    as.data.frame(stats::setNames(lapply(cols, function(c) if (is.null(b[[c]])) NA_character_ else b[[c]]$value), cols),
                  stringsAsFactors = FALSE)
  })
  if (length(rows) == 0) {
    return(as.data.frame(stats::setNames(rep(list(character()), length(cols)), cols)))
  }
  bind_rows_base(rows)
}
