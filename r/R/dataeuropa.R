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

#' Collapse a multilingual `{lang: text}` list to one string
#'
#' @param x A named list of translations (or a string).
#' @param lang Preferred language code; falls back to English, then any.
#' @return A character scalar, or `NA_character_`.
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
  req <- do.call(httr2::req_url_query, c(list(de_req(paste0(SEARCH_URL, "/search"))), p))
  de_json(httr2::req_perform(req))$result
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
#' @export
de_count <- function(q = NULL, ...) as.integer(de_search(q, limit = 0, ...)$count)

#' Full metadata for one dataset
#'
#' @param id Dataset id as shown in search results.
#' @param raw If `TRUE` return the untouched nested list.
#' @param lang Preferred language.
#' @export
de_get_dataset <- function(id, raw = FALSE, lang = "en") {
  d <- de_json(httr2::req_perform(de_req(paste0(SEARCH_URL, "/datasets/", id))))$result
  if (raw) return(d)
  list(summary = de_summarise(d, lang), keywords = de_keywords(d, lang), raw = d)
}

# Keyword labels in `lang`, plus those with no language tag.
de_keywords <- function(d, lang = "en") {
  kw <- unlist(lapply(d$keywords, function(k) if (is.null(k$language) || identical(k$language, lang)) k$label))
  if (is.null(kw)) character() else kw
}

#' Distributions (files and services) of a dataset
#'
#' The `url` column is the download URL if present, otherwise the access URL.
#' @inheritParams de_get_dataset
#' @export
de_distributions <- function(id, lang = "en") de_distribution_table(de_get_dataset(id, raw = TRUE), lang)

# One row per distribution of a raw dataset record; `url` is the download URL, else the access URL.
de_distribution_table <- function(d, lang = "en") {
  rows <- lapply(d$distributions %||% list(), function(x) {
    dl <- chr(x$download_url); ac <- chr(x$access_url)
    data.frame(id = chr(x$id), title = de_pick_lang(x$title, lang), format = chr(x$format$id),
               media_type = chr(x$media_type),
               byte_size = suppressWarnings(as.numeric(chr(x$byte_size))),
               license = chr(x$license$id), modified = chr(x$modified),
               download_url = dl, access_url = ac, url = if (is.na(dl)) ac else dl,
               stringsAsFactors = FALSE)
  })
  bind_rows_base(rows)
}

#' Download a distribution to disk
#'
#' @param x A URL, or a one-row data frame from [de_distributions()].
#' @param dest File path or directory (default: current directory).
#' @return The local path, invisibly.
#' @export
de_download <- function(x, dest = ".") {
  url <- if (is.character(x)) x else x$url[[1]]
  name <- utils::URLdecode(basename(sub("[?#].*$", "", url)))
  if (!nzchar(name)) name <- "download"
  path <- if (dir.exists(dest)) file.path(dest, name) else dest
  httr2::req_perform(de_req(url), path = path)
  invisible(path)
}

#' Values and counts of a facet
#'
#' @param facet e.g. "country", "format", "categories", "catalog", "publisher".
#' @param top Keep the `top` most frequent values (NULL for all).
#' @inheritParams de_search_datasets
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
#' @export
de_catalogues <- function() unlist(de_json(httr2::req_perform(de_req(paste0(SEARCH_URL, "/catalogues")))))

#' Dataset metadata as RDF text
#' @param id Dataset id.
#' @param fmt "ttl" (Turtle) or "jsonld".
#' @export
de_get_rdf <- function(id, fmt = c("ttl", "jsonld")) {
  fmt <- match.arg(fmt)
  httr2::resp_body_string(httr2::req_perform(de_req(paste0(REPO_URL, "/datasets/", id, ".", fmt))))
}

#' Run a SPARQL query against data.europa.eu
#'
#' @param query SPARQL SELECT or ASK text.
#' @return A data frame of plain string values (SELECT) or a logical (ASK).
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
