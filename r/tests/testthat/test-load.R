# load_distribution offline: de_download() is replaced by a copy of a local file named by the URL's
# last part (from fixtures/files, or from a temporary folder for files made in the test).

files <- normalizePath(file.path("..", "..", "..", "fixtures", "files"), mustWork = FALSE)
scratch <- tempfile("load-test")
dir.create(scratch)

fake_download <- function(x, dest = ".", verify = TRUE) {
  url <- if (is.character(x)) x else x$url[[1]]
  name <- sub("[?#].*$", "", sub("^.*/", "", url))
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
  skip_on_cran()
  # A small, dated Latin-1 CSV with semicolons on data.gouv.fr (2018 budget of a French commune).
  dist <- de_distributions("5be153fa8b4c417561300530")
  df <- de_load_distribution(dist[dist$format == "CSV", ][1, ])
  expect_gt(nrow(df), 0)
  expect_true("D\u00e9penses" %in% names(df))
})

test_that("checksums are normalised", {
  ck <- dataeuropa:::de_checksum
  expect_equal(ck(list(algorithm = "SHA-256", checksum_value = " AB12 ")), list(algorithm = "sha256", value = "ab12"))
  expect_equal(ck(list(algorithm = "http://spdx.org/rdf/terms#checksumAlgorithm_sha1", checksum_value = "x"))$algorithm,
               "sha1")
  expect_equal(ck(list(checksum_value = strrep("0", 40)))$algorithm, "sha1")
  expect_equal(ck(list(checksum_value = "not-a-hash")), list(algorithm = NA_character_, value = "not-a-hash"))
  expect_equal(ck(list(checksum_value = "")), list(algorithm = NA_character_, value = NA_character_))
  expect_equal(ck(NULL), list(algorithm = NA_character_, value = NA_character_))
})

test_that("de_download checks the checksum", {
  skip_if_not(dir.exists(files), "fixtures folder not available")
  # Stand in for the HTTP request: write the bytes of fixtures/files/<last part of the URL>.
  local_mocked_bindings(de_fetch_to = function(url, part, resume = TRUE, max_bytes = NULL) {
    file.copy(file.path(files, sub("^.*/", "", url)), part, overwrite = TRUE)
    invisible(part)
  }, .package = "dataeuropa")
  good <- dataeuropa:::de_file_hash(file.path(files, "comma.csv"), "sha1")
  row <- data.frame(url = "https://x.example/comma.csv", checksum = good, checksum_algorithm = "sha1")
  expect_match(de_download(row, scratch), "comma.csv$")
  bad <- transform(row, checksum = strrep("0", 40))
  expect_error(de_download(bad, file.path(scratch, "bad.csv")), "checksum mismatch")
  expect_false(file.exists(file.path(scratch, "bad.csv")))                       # deleted
  expect_true(file.exists(de_download(bad, file.path(scratch, "kept.csv"), verify = FALSE)))
  expect_true(file.exists(de_download(transform(row, checksum = NA, checksum_algorithm = NA),
                                      file.path(scratch, "a.csv"))))
  expect_true(file.exists(de_download(transform(row, checksum = "1a2b", checksum_algorithm = "crc"),
                                      file.path(scratch, "b.csv"))))
  expect_error(de_load_distribution(list(url = "https://x.example/semicolon.csv", format = "CSV",
                                         checksum = strrep("0", 32), checksum_algorithm = "md5")),
               "checksum mismatch")
})

test_that("live download checked against a SHA-1 checksum", {
  skip_if(Sys.getenv("DATAEUROPA_OFFLINE") == "1", "offline")
  skip_on_cran()
  # A 2 MB CSV on dados.gov.pt whose distribution carries a SHA-1 checksum.
  dist <- de_distributions("68c2be5c43136b247fe74d41")
  row <- dist[!is.na(dist$checksum_algorithm) & dist$checksum_algorithm == "sha1", ][1, ]
  expect_true(file.exists(de_download(row, scratch)))
})

test_that("pages are refused, and files_only keeps only files", {
  expect_error(de_load_distribution(list(url = "https://example.org/dataset/1", format = "HTML")), "web page")
  skip_if_not(dir.exists(files), "fixtures folder not available")
  record <- jsonlite::fromJSON(file.path(files, "..", "responses", "edge_cases.json"), simplifyVector = FALSE)$dataset
  local_mocked_bindings(de_get_dataset = function(...) record, .package = "dataeuropa")
  every <- de_distributions("x")
  only <- de_distributions("x", files_only = TRUE)
  expect_setequal(every$kind, c("file", "service", "unknown", "none"))
  expect_equal(only$id, every$id[every$kind == "file"])
})

test_that("live files_only", {
  skip_if(Sys.getenv("DATAEUROPA_OFFLINE") == "1", "offline")
  skip_on_cran()
  every <- de_distributions("3b26eacb-825d-4bf9-9ef2-9278c4a481ad")
  only <- de_distributions("3b26eacb-825d-4bf9-9ef2-9278c4a481ad", files_only = TRUE)
  expect_true(nrow(only) > 0 && nrow(only) < nrow(every) && all(only$kind == "file"))
})
