# load_distribution offline: de_download() is replaced by a copy of a local file named by the URL's
# last part (from fixtures/files, or from a temporary folder for files made in the test).

files <- normalizePath(file.path("..", "..", "..", "fixtures", "files"), mustWork = FALSE)
scratch <- tempfile("load-test")
dir.create(scratch)

fake_download <- function(x, dest = ".") {
  name <- sub("[?#].*$", "", sub("^.*/", "", x))
  src <- if (file.exists(file.path(files, name))) file.path(files, name) else file.path(scratch, name)
  file.copy(src, dest, overwrite = TRUE)
  invisible(dest)
}

test_that("de_load_distribution reads by detected format", {
  skip_if_not(dir.exists(files), "fixtures folder not available")
  local_mocked_bindings(de_download = fake_download, .package = "dataeuropa")
  df <- de_load_distribution(data.frame(url = "https://x.example/semicolon.csv", format = "CSV",
                                        media_type = NA_character_))
  expect_equal(names(df), c("city", "population", "share"))
  expect_equal(nrow(df), 2)
  skip_if_not_installed("arrow")
  expect_equal(names(de_load_distribution("https://x.example/table.parquet")), c("id", "value", "label"))
  skip_if_not_installed("readxl")
  expect_equal(de_load_distribution("https://x.example/table.xlsx", sheet = "Second")$k, c("x", "y"))
  expect_equal(de_load_distribution("https://x.example/table.xlsx", sheet = 2)$k, c("x", "y"))
  expect_equal(de_load_distribution("https://x.example/wrapped.json", format = "json")$code, c("PT", "ES"))
})

test_that("de_load_distribution refuses what it cannot read", {
  local_mocked_bindings(de_download = fake_download, .package = "dataeuropa")
  expect_error(de_load_distribution(list(url = "https://x.example/wms", format = "WMS_SRVC")), "service")
  expect_error(de_load_distribution(list(url = "https://x.example/get", format = "CSV",
                                         media_type = "application/zip")), "archive")
  expect_error(de_load_distribution("https://x.example/data"), "cannot tell")
  expect_error(de_load_distribution("https://x.example/a.csv", format = "shapefile"), "format must be")
  expect_error(de_load_distribution(list(url = NA)), "no URL")
  writeLines("<!DOCTYPE html><html><body>Landing page</body></html>", file.path(scratch, "page.csv"))
  expect_error(de_load_distribution("https://x.example/page.csv"), "HTML page")
  writeBin(as.raw(c(0x50, 0x4b, 0x03, 0x04, 0x00)), file.path(scratch, "zipped.csv"))
  expect_error(de_load_distribution("https://x.example/zipped.csv"), "archive")
  writeLines("[1, 2, 3]", file.path(scratch, "list.json"))
  expect_error(de_load_distribution("https://x.example/list.json"), "not a table")
})

test_that("live load of a real CSV", {
  skip_if(Sys.getenv("DATAEUROPA_OFFLINE") == "1", "offline")
  # A small, dated Latin-1 CSV with semicolons on data.gouv.fr (2018 budget of a French commune).
  dist <- de_distributions("5be153fa8b4c417561300530")
  df <- de_load_distribution(dist[dist$format == "CSV", ][1, ])
  expect_gt(nrow(df), 0)
  expect_true("D\u00e9penses" %in% names(df))
})
