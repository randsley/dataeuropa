# de_load_geodata: geodata files into sf data frames.

geo <- normalizePath(file.path("..", "..", "..", "fixtures", "files", "geo"), mustWork = FALSE)

# Serve fixtures/files/geo/<name> in place of the network; the size limit behaves as in de_download().
local_geo_files <- function(env = parent.frame()) {
  local_mocked_bindings(de_download = function(x, dest = ".", verify = TRUE, resume = TRUE, max_bytes = NULL) {
    url <- if (is.character(x)) x else x$url
    src <- file.path(geo, sub("^.*/", "", url))
    if (!is.null(max_bytes) && file.size(src) > max_bytes) stop(dataeuropa:::too_large(url, max_bytes))
    file.copy(src, dest)
    invisible(dest)
  }, .package = "dataeuropa", .env = env)
}

test_that("a zipped shapefile loads from a distribution row", {
  skip_if_not_installed("sf")
  skip_if_not(dir.exists(geo), "fixtures folder not available")
  local_geo_files()
  row <- data.frame(url = "https://example.org/roads.zip", format = "SHP", media_type = "application/zip")
  df <- de_load_geodata(row)
  expect_s3_class(df, "sf")
  expect_equal(df$name, c("A1", "A2"))
  expect_equal(sf::st_crs(df)$epsg, 3763L)
})

test_that("layers are picked by name or position, and data can be reprojected", {
  skip_if_not_installed("sf")
  skip_if_not(dir.exists(geo), "fixtures folder not available")
  local_geo_files()
  expect_message(first <- de_load_geodata("https://example.org/layers.gpkg"), "2 layers")
  expect_equal(names(first), c("code", "area", "geometry"))
  expect_equal(attr(first, "sf_column"), "geometry")            # GeoPackages call it `geom`
  wells <- de_load_geodata("https://example.org/layers.gpkg", layer = 2, crs = "EPSG:4326")
  expect_equal(nrow(wells), 2)
  expect_equal(sf::st_crs(wells)$epsg, 4326L)
  expect_equal(de_load_geodata("https://example.org/two_shapes.zip", layer = "rivers")$name, "Tejo")
  expect_error(de_load_geodata("https://example.org/two_shapes.zip"), "2 geodata files")
  expect_error(de_load_geodata("https://example.org/layers.gpkg", layer = 3), "out of range")
})

test_that("data without a coordinate reference system warns", {
  skip_if_not_installed("sf")
  skip_if_not(dir.exists(geo), "fixtures folder not available")
  local_geo_files()
  expect_warning(df <- de_load_geodata("https://example.org/no_prj.zip"), "no coordinate reference system")
  expect_true(is.na(sf::st_crs(df)))
  expect_error(de_load_geodata("https://example.org/no_prj.zip", crs = "EPSG:4326"), "cannot be reprojected")
})

test_that("large files, services and pages are refused", {
  skip_if_not_installed("sf")
  skip_if_not(dir.exists(geo), "fixtures folder not available")
  local_geo_files()
  expect_error(de_load_geodata("https://example.org/layers.gpkg", max_mb = 0.0001),
               "larger than 0.0001 MB; pass max_mb = Inf", fixed = TRUE)
  expect_equal(nrow(de_load_geodata("https://example.org/points.geojson", max_mb = Inf)), 3)
  expect_error(de_load_geodata(list(url = "https://example.org/wms?service=WMS&request=GetCapabilities",
                                    format = "WMS")), "cannot read; it reads files, WFS and OGC API Features")
  expect_error(de_load_geodata(list(url = "https://example.org/map", format = "HTML")), "web page")
})

# ---------------------------------------------------------------- feature services

# A minimal OGC API Features server, as fixtures/README.md describes: the collections in
# fixtures/files/oapif/*.geojson under /custom/oapif, three features per page with `next` links.
# It runs in its own R process (callr), with R's built-in HTTP server.
oapif_dir <- normalizePath(file.path("..", "..", "..", "fixtures", "files", "oapif"), mustWork = FALSE)
oapif_port_file <- tempfile("oapif-port")
oapif <- if (requireNamespace("callr", quietly = TRUE) && dir.exists(oapif_dir)) callr::r_bg(function(dir, port_file) {
  files <- list.files(dir, pattern = "[.]geojson$", full.names = TRUE)
  collections <- stats::setNames(lapply(files, function(f) jsonlite::fromJSON(f, simplifyVector = FALSE)$features),
                                 sub("[.]geojson$", "", basename(files)))
  json <- function(x) list(payload = as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", digits = NA)),
                           "content-type" = "application/json", "status code" = 200L)
  handler <- function(path, query, body, headers) {
    port <- readLines(port_file)
    base <- sprintf("http://127.0.0.1:%s/custom/oapif", port)
    segs <- strsplit(sub("^/custom/oapif/?", "", sub("/+$", "", path)), "/")[[1]]
    collection <- function(name) list(id = name, title = name, links = list(list(
      href = paste0(base, "/collections/", name, "/items"), rel = "items", type = "application/geo+json")))
    if (length(segs) == 0) return(json(list(links = list(list(href = paste0(base, "/collections"), rel = "data",
                                                                type = "application/json")))))
    if (identical(segs, "collections")) return(json(list(collections = unname(lapply(names(collections), collection)))))
    if (length(segs) >= 2 && segs[1] == "collections" && segs[2] %in% names(collections)) {
      if (length(segs) == 2) return(json(collection(segs[2])))
      if (length(segs) == 3 && segs[3] == "items") {
        features <- collections[[segs[2]]]
        param <- function(k, default) if (k %in% names(query)) as.integer(query[[k]]) else default
        limit <- param("limit", 3L)
        offset <- param("offset", 0L)
        n <- max(0L, min(min(limit, 3L), length(features) - offset))
        page <- if (n > 0) features[offset + seq_len(n)] else list()
        links <- if (offset + n < length(features)) list(list(
          href = sprintf("%s/collections/%s/items?limit=%d&offset=%d", base, segs[2], limit, offset + n),
          rel = "next", type = "application/geo+json")) else list()
        return(json(list(type = "FeatureCollection", features = page, links = links,
                         numberMatched = length(features))))
      }
    }
    list(payload = '{"code": "NotFound"}', "content-type" = "application/json", "status code" = 404L)
  }
  assign("oapif", handler, envir = get(".httpd.handlers.env", asNamespace("tools")))
  port <- suppressMessages(tools::startDynamicHelp(NA))
  writeLines(as.character(port), port_file)
  repeat Sys.sleep(0.05)
}, args = list(dir = oapif_dir, port_file = oapif_port_file)) else NULL
if (!is.null(oapif)) withr::defer(oapif$kill(), envir = testthat::teardown_env())
oapif_base <- NULL
if (!is.null(oapif)) for (i in 1:100) {   # wait up to 10 s for the server to start
  if (file.exists(oapif_port_file) && length(readLines(oapif_port_file))) {
    oapif_base <- sprintf("http://127.0.0.1:%s/custom/oapif", readLines(oapif_port_file)); break
  }
  if (!oapif$is_alive()) break
  Sys.sleep(0.1)
}

test_that("OGC API Features collections load, by URL or landing page", {
  skip_if_not_installed("sf")
  skip_if(is.null(oapif_base), "no local OGC API Features server")
  df <- de_load_geodata(list(url = paste0(oapif_base, "/collections/places"), format = "OGCFEAT"))
  expect_equal(nrow(df), 7)
  expect_equal(df$name[1:2], c("P1", "P2"))
  expect_equal(sf::st_crs(df)$epsg, 4326L)
  expect_equal(attr(df, "sf_column"), "geometry")
  expect_message(df <- de_load_geodata(list(url = oapif_base, format = "OGCFEAT")), "2 layers")
  expect_equal(nrow(df), 7)
  roads <- de_load_geodata(paste0(oapif_base, "/collections/roads/items?f=json"), layer = 1, crs = "EPSG:3035")
  expect_equal(nrow(roads), 2)
  expect_equal(sf::st_crs(roads)$epsg, 3035L)
  expect_equal(nrow(de_load_geodata(list(url = oapif_base, format = "OGCFEAT"), layer = "roads")), 2)
})

test_that("a feature limit stops reading services early", {
  skip_if_not_installed("sf")
  skip_if(is.null(oapif_base), "no local OGC API Features server")
  url <- paste0(oapif_base, "/collections/places")
  expect_warning(df <- de_load_geodata(url, max_features = 4), "more than 4 features; read the first 4")
  expect_equal(df$id, 1:4)
  expect_no_warning(expect_equal(nrow(de_load_geodata(url, max_features = 7)), 7))
  expect_no_warning(expect_equal(nrow(de_load_geodata(url, max_features = Inf)), 7))
})

test_that("live feature services", {
  skip_if(Sys.getenv("DATAEUROPA_OFFLINE") == "1", "offline")
  skip_if_not_installed("sf")
  for (fmt in c("WFS_SRVC", "OGCFEAT")) {
    found <- FALSE
    for (id in de_search_datasets(facets = list(format = fmt), limit = 20)$id) {
      rows <- de_distributions(id)
      for (i in seq_len(nrow(rows))) {
        if (is.na(dataeuropa:::de_service_source(rows$format[i], rows$url[i]))) next
        df <- tryCatch(suppressWarnings(de_load_geodata(rows[i, ], max_features = 20)), error = function(e) NULL)
        if (is.null(df)) next   # unreachable hosts and broken services are common; try the next one
        expect_s3_class(df, "sf")
        expect_true(nrow(df) > 0 && nrow(df) <= 20)
        found <- TRUE
        break
      }
      if (found) break
    }
    if (!found) message("no working ", fmt, " service among the first results")
  }
})

test_that("live GeoJSON", {
  skip_if(Sys.getenv("DATAEUROPA_OFFLINE") == "1", "offline")
  skip_if_not_installed("sf")
  ids <- de_search_datasets(facets = list(format = "GEOJSON"), limit = 20)$id
  for (id in ids) {
    files <- de_distributions(id, files_only = TRUE)
    files <- files[toupper(files$format) %in% "GEOJSON", , drop = FALSE]
    if (!nrow(files)) next
    df <- tryCatch(de_load_geodata(files[1, ], max_mb = 20), error = function(e) NULL)
    if (is.null(df)) next   # dead links and oversized files are common; try the next dataset
    expect_s3_class(df, "sf")
    expect_equal(attr(df, "sf_column"), "geometry")
    return(invisible())
  }
  skip("no small, working GeoJSON distribution among the first results")
})
