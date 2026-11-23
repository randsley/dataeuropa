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
  expect_error(de_load_geodata(list(url = "https://example.org/wfs?service=WFS&request=GetCapabilities",
                                    format = "WFS")), "is a service")
  expect_error(de_load_geodata(list(url = "https://example.org/map", format = "HTML")), "web page")
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
