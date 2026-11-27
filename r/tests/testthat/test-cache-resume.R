# Response cache and resumable downloads.

# ---------------------------------------------------------------- response cache

# Replace the HTTP call with one that counts requests; the cache goes to a temporary folder.
local_counting_http <- function(env = parent.frame()) {
  calls <- new.env()
  calls$urls <- character()
  calls$limits <- numeric()
  local_mocked_bindings(de_http_get = function(url, query = list()) {
    calls$urls <- c(calls$urls, url)
    if (!is.null(query$limit)) calls$limits <- c(calls$limits, query$limit)
    if (endsWith(url, "/catalogues")) return('["a","b"]')
    if (grepl("/datasets/", url)) return(sprintf('{"result":{"id":"%s","distributions":[]}}', sub("^.*/", "", url)))
    '{"result":{"count":7,"results":[],"facets":[]}}'
  }, .package = "dataeuropa", .env = env)
  cache <- dataeuropa:::.de_cache
  old <- as.list(cache)
  rm(list = ls(cache), envir = cache)
  withr::defer({ rm(list = ls(cache), envir = cache); list2env(old, cache) }, envir = env)
  withr::local_envvar(DATAEUROPA_CACHE = NA, DATAEUROPA_CACHE_TTL = NA,
                      DATAEUROPA_CACHE_DIR = file.path(withr::local_tempdir(.local_envir = env), "cache"),
                      .local_envir = env)
  calls
}

test_that("the cache is off by default", {
  calls <- local_counting_http()
  de_catalogues(); de_catalogues()
  expect_length(calls$urls, 2)
})

test_that("the cache serves repeat requests", {
  calls <- local_counting_http()
  expect_equal(de_cache_on(), Sys.getenv("DATAEUROPA_CACHE_DIR"))
  for (i in 1:2) {
    expect_equal(de_catalogues(), c("a", "b"))
    expect_equal(de_get_dataset("x1", raw = TRUE)$id, "x1")
    expect_equal(de_count("water"), 7)                     # limit = 0: cacheable
    de_search("water", limit = 5)                          # returns records: never cached
  }
  expect_equal(sum(endsWith(calls$urls, "/catalogues")), 1)
  expect_equal(sum(endsWith(calls$urls, "/datasets/x1")), 1)
  expect_equal(calls$limits, c(0, 5, 5))
  de_count("other")                                        # other parameters: a new entry
  expect_length(calls$urls, 6)
  expect_equal(de_clear_cache(), 4)
  de_catalogues()
  expect_length(calls$urls, 7)
  de_cache_off()
  de_catalogues()
  expect_length(calls$urls, 8)
})

test_that("the cache has a time limit", {
  calls <- local_counting_http()
  de_cache_on(ttl = 0)                                     # every entry is already too old
  de_catalogues(); de_catalogues()
  expect_length(calls$urls, 2)
})

test_that("the cache can be turned on from the environment", {
  calls <- local_counting_http()
  withr::local_envvar(DATAEUROPA_CACHE = "1")
  de_catalogues(); de_catalogues()
  expect_length(calls$urls, 1)
})

# ---------------------------------------------------------------- resumable downloads

# One file served by R's built-in HTTP server, with ranges, Last-Modified and If-Range like a real
# host. The server runs in a separate R process (callr): in this process it would only answer while
# R's event loop runs, which a blocking download does not do on Linux. The test and the server
# share a folder: body.bin and modified.txt are the served file, ranges.txt logs each Range header.
shared <- tempfile("dataeuropa-server")
dir.create(shared)

set_file <- function(body = NULL, modified = NULL) {
  if (!is.null(body)) writeBin(body, file.path(shared, "body.bin"))
  if (!is.null(modified)) writeLines(modified, file.path(shared, "modified.txt"))
}
served <- function() list(body = readBin(file.path(shared, "body.bin"), "raw", 1e6),
                          modified = readLines(file.path(shared, "modified.txt")))
ranges <- function() {
  f <- file.path(shared, "ranges.txt")
  if (!file.exists(f)) return(list())
  lapply(readLines(f), function(r) if (r == "NONE") NULL else r)
}
reset_state <- function() {
  unlink(file.path(shared, "ranges.txt"))
  set_file(as.raw(rep(0:255, 40)), "Thu, 11 Sep 2025 12:19:52 GMT")
}
reset_state()

server <- callr::r_bg(function(shared) {
  header_value <- function(headers, name) {
    lines <- strsplit(rawToChar(headers), "\r?\n")[[1]]
    hit <- lines[startsWith(tolower(lines), paste0(tolower(name), ":"))]
    if (length(hit)) trimws(sub("^[^:]*:", "", hit[1])) else NULL
  }
  serve_file <- function(path, query, body, headers) {
    b <- readBin(file.path(shared, "body.bin"), "raw", 1e6)
    modified <- readLines(file.path(shared, "modified.txt"))
    rng <- header_value(headers, "Range")
    ifr <- header_value(headers, "If-Range")
    cat(if (is.null(rng)) "NONE" else rng, "\n", sep = "", file = file.path(shared, "ranges.txt"), append = TRUE)
    if (!is.null(rng) && (is.null(ifr) || ifr == modified)) {
      start <- as.numeric(sub("-$", "", sub("^bytes=", "", rng)))
      if (start >= length(b))
        return(list(payload = raw(), "content-type" = "application/octet-stream",
                    headers = paste0("Content-Range: bytes */", length(b)), "status code" = 416L))
      return(list(payload = b[(start + 1):length(b)], "content-type" = "application/octet-stream",
                  headers = c(sprintf("Content-Range: bytes %d-%d/%d", start, length(b) - 1, length(b)),
                              paste("Last-Modified:", modified)),
                  "status code" = 206L))
    }
    list(payload = b, "content-type" = "application/octet-stream",
         headers = paste("Last-Modified:", modified), "status code" = 200L)
  }
  assign("dataeuropa-test", serve_file, envir = get(".httpd.handlers.env", asNamespace("tools")))
  port <- suppressMessages(tools::startDynamicHelp(NA))
  writeLines(as.character(port), file.path(shared, "port.txt"))
  repeat Sys.sleep(0.05)   # keep the process, and with it the server, alive
}, args = list(shared = shared))
withr::defer(server$kill(), envir = testthat::teardown_env())

port <- 0L
for (i in 1:100) {   # wait up to 10 s for the server to start
  if (file.exists(file.path(shared, "port.txt"))) { port <- as.integer(readLines(file.path(shared, "port.txt"))); break }
  if (!server$is_alive()) break
  Sys.sleep(0.1)
}
url <- sprintf("http://127.0.0.1:%d/custom/dataeuropa-test/data.bin", port)

# Leave the first `n` bytes as a partial download, as an interrupted call would.
interrupted <- function(folder, n, from = url) {
  writeBin(served()$body[seq_len(n)], file.path(folder, "data.bin.part"))
  writeLines(jsonlite::toJSON(list(url = from, validator = served()$modified), auto_unbox = TRUE),
             file.path(folder, "data.bin.part.json"))
}

test_that("downloads leave no partial files", {
  skip_if(port == 0, "no local HTTP server")
  reset_state(); tmp <- withr::local_tempdir()
  expect_equal(readBin(de_download(url, tmp), "raw", 1e5), served()$body)
  expect_equal(list.files(tmp, all.files = TRUE, no.. = TRUE), "data.bin")
})

test_that("a size limit stops large downloads", {
  skip_if(port == 0, "no local HTTP server")
  reset_state(); tmp <- withr::local_tempdir()
  expect_error(de_download(url, tmp, max_bytes = 1000), "larger than the limit of 1,000 bytes", class = "dataeuropa_too_large")
  expect_length(list.files(tmp, all.files = TRUE, no.. = TRUE), 0)
  expect_equal(readBin(de_download(url, tmp, max_bytes = 20000), "raw", 1e5), served()$body)
})

test_that("an interrupted download resumes", {
  skip_if(port == 0, "no local HTTP server")
  reset_state(); tmp <- withr::local_tempdir(); interrupted(tmp, 1000)
  expect_equal(readBin(de_download(url, tmp), "raw", 1e5), served()$body)
  expect_equal(ranges(), list("bytes=1000-"))
  expect_equal(list.files(tmp, all.files = TRUE, no.. = TRUE), "data.bin")
})

test_that("a file that changed meanwhile is downloaded again", {
  skip_if(port == 0, "no local HTTP server")
  reset_state(); tmp <- withr::local_tempdir(); interrupted(tmp, 1000)
  set_file(charToRaw(strrep("new content", 100)), "Fri, 12 Sep 2025 08:00:00 GMT")
  expect_equal(readBin(de_download(url, tmp), "raw", 1e5), served()$body)
})

test_that("a partial file longer than the file starts again", {
  skip_if(port == 0, "no local HTTP server")
  reset_state(); tmp <- withr::local_tempdir(); interrupted(tmp, 1000)
  set_file(served()$body[1:500])
  expect_equal(readBin(de_download(url, tmp), "raw", 1e5), served()$body)
  expect_equal(ranges(), list("bytes=1000-", NULL))
})

test_that("resume = FALSE and a partial file of another URL start from the start", {
  skip_if(port == 0, "no local HTTP server")
  reset_state(); tmp <- withr::local_tempdir(); interrupted(tmp, 1000)
  expect_equal(readBin(de_download(url, tmp, resume = FALSE), "raw", 1e5), served()$body)
  interrupted(tmp, 1000, from = "http://elsewhere.example/data.bin")
  expect_equal(readBin(de_download(url, file.path(tmp, "data.bin")), "raw", 1e5), served()$body)
  expect_equal(ranges(), list(NULL, NULL))
})

test_that("live resume, checked by SHA-1", {
  skip_if(Sys.getenv("DATAEUROPA_OFFLINE") == "1", "offline")
  skip_on_cran()
  # Resume the dados.gov.pt CSV from half way; its SHA-1 checksum proves the result is exact.
  tmp <- withr::local_tempdir()
  dist <- de_distributions("68c2be5c43136b247fe74d41")
  row <- dist[!is.na(dist$checksum_algorithm) & dist$checksum_algorithm == "sha1", ][1, ]
  whole <- de_download(row, file.path(tmp, "whole.csv"))
  data <- readBin(whole, "raw", file.size(whole))
  lm <- httr2::resp_header(httr2::req_perform(httr2::req_method(httr2::request(row$url), "HEAD")), "last-modified")
  expect_false(is.null(lm))
  writeBin(data[seq_len(length(data) %/% 2)], file.path(tmp, "half.csv.part"))
  writeLines(jsonlite::toJSON(list(url = row$url, validator = lm), auto_unbox = TRUE),
             file.path(tmp, "half.csv.part.json"))
  half <- de_download(row, file.path(tmp, "half.csv"))
  expect_equal(readBin(half, "raw", file.size(half)), data)
})
