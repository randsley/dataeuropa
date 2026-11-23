# Shared conformance cases (fixtures/cases.json): the same inputs must give the same tables in
# Python, Julia and R. Expected outputs come from the Python reference (fixtures/make_expected.py).
# The fixtures live outside the package, so these tests run from a source checkout only.

fixtures <- normalizePath(file.path("..", "..", "..", "fixtures"), mustWork = FALSE)
read_fixture <- function(path) jsonlite::fromJSON(file.path(fixtures, path), simplifyVector = FALSE)

# Bring an R value and an expected JSON value to comparable plain values.
norm_value <- function(x, col = "") {
  if (is.null(x) || (length(x) == 1 && is.atomic(x) && is.na(x))) return(NULL)
  if (col == "formats" && is.character(x)) return(if (nzchar(x)) as.list(strsplit(x, ",")[[1]]) else list())
  if (is.list(x)) return(lapply(x, norm_value))
  if (is.numeric(x)) return(as.numeric(x))
  x
}

run_case <- function(case) {
  args <- case$args
  if (case$kind == "read_file") {
    df <- dataeuropa:::de_read_table(file.path(fixtures, case$input), args$format, args$sheet)
    return(list(columns = as.list(names(df)), rows = df))
  }
  if (case$kind == "read_geo") {
    df <- tryCatch(suppressWarnings(suppressMessages(
      dataeuropa:::de_read_geodata(file.path(fixtures, case$input), args$layer, args$crs))), error = function(e) NULL)
    return(if (is.null(df)) list(error = TRUE) else dataeuropa:::de_geo_summary(df, args$columns))
  }
  if (case$kind == "file_hash")
    return(list(values = lapply(args$algorithms, function(a)
      dataeuropa:::de_file_hash(file.path(fixtures, case$input), a))))
  data <- read_fixture(case$input)
  if (!is.null(case$select)) data <- data[[case$select]]
  switch(case$kind,
    geo_format = list(values = lapply(data, function(r) {
      f <- dataeuropa:::de_geo_format(r$format, r$media_type, r$url)
      if (is.na(f)) NULL else f
    })),
    service_source = list(values = lapply(data, function(r) {
      s <- dataeuropa:::de_service_source(r$format, r$url)
      if (is.na(s)) NULL else s
    })),
    geo_member = list(values = lapply(data, function(r) tryCatch({
      p <- dataeuropa:::de_geo_member(r$names, r$layer)
      list(p$member, p$layer)
    }, error = function(e) "error"))),
    distribution_kind = list(values = lapply(data, function(r)
      dataeuropa:::de_distribution_kind(r$format, r$media_type, r$url, r$download_url))),
    range_validator = list(values = lapply(data, function(r) dataeuropa:::de_range_validator(r$etag, r$last_modified))),
    resume_action = list(values = lapply(data, function(r)
      dataeuropa:::de_resume_action(r$status, r$content_range, r$offset))),
    file_format = list(values = lapply(data, function(r) {
      f <- dataeuropa:::de_file_format(r$format, r$media_type, r$url)
      if (is.na(f)) NULL else f
    })),
    summarise = list(rows = dataeuropa:::bind_rows_base(lapply(data, dataeuropa:::de_summarise, lang = args$lang))),
    distributions = list(rows = dataeuropa:::de_distribution_table(data, args$lang)),
    keywords = list(values = as.list(dataeuropa:::de_keywords(data, args$lang))),
    facets = list(rows = dataeuropa:::de_facet_table(data, args$facet, args$top)),
    sparql = {
      res <- dataeuropa:::de_sparql_table(data)
      if (is.logical(res)) list(boolean = res) else list(rows = res)
    },
    stop("unknown kind ", case$kind))
}

# A geodata summary against the expected one; bounds to within a millimetre (or 1e-9 degrees).
check_geo <- function(got, expected, name) {
  if (isTRUE(expected$error)) return(expect_true(isTRUE(got$error), label = paste(name, "fails")))
  expect_null(got$error, label = paste(name, "error"))
  for (k in c("columns", "values", "nrow", "geometry_types", "crs"))
    expect_equal(norm_value(got[[k]]), norm_value(expected[[k]]), label = paste(name, k))
  expect_equal(as.numeric(unlist(got$bounds)), as.numeric(unlist(expected$bounds)), tolerance = 1e-9,
               label = paste(name, "bounds"))
}

test_that("conformance cases match the Python reference", {
  skip_if_not(dir.exists(fixtures), "fixtures folder not available")
  for (case in read_fixture("cases.json")$cases) {
    if (case$kind == "read_geo" && !requireNamespace("sf", quietly = TRUE)) next
    expected <- read_fixture(file.path("expected", paste0(case$name, ".json")))
    got <- run_case(case)
    if (case$kind == "read_geo") {
      check_geo(got, expected, case$name)
      next
    }
    if (!is.null(expected$columns))
      expect_equal(got$columns, expected$columns, label = paste(case$name, "columns"))
    if (!is.null(expected$rows)) {
      df <- got$rows
      expect_equal(nrow(df), length(expected$rows), label = paste(case$name, "row count"))
      for (i in seq_along(expected$rows)) for (col in names(expected$rows[[i]])) {
        gv <- if (col %in% names(df)) norm_value(df[[col]][[i]], col) else NULL
        ev <- norm_value(expected$rows[[i]][[col]], col)
        expect_equal(gv, ev, label = sprintf("%s row %d column %s", case$name, i, col))
      }
    } else if (!is.null(expected$values)) {
      expect_equal(norm_value(got$values), norm_value(expected$values), label = paste(case$name, "values"))
    } else {
      expect_identical(got$boolean, expected$boolean, label = case$name)
    }
  }
})
