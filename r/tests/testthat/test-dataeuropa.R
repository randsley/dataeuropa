test_that("de_pick_lang picks language, then en, then any", {
  expect_equal(de_pick_lang(list(pt = "olá", en = "hi"), "pt"), "olá")
  expect_equal(de_pick_lang(list(pt = "olá", en = "hi"), "fr"), "hi")
  expect_equal(de_pick_lang(list(de = "hallo"), "fr"), "hallo")
  expect_true(is.na(de_pick_lang(NULL)))
})

test_that("de_facets normalises convenience filters", {
  f <- dataeuropa:::de_facets(list(catalog = "a"), country = c("PT", "ES"), hvd = TRUE, format = "CSV", license = NULL)
  expect_equal(f$country, c("pt", "es"))
  expect_equal(f$is_hvd, "true")
  expect_equal(f$format, "CSV")
  expect_equal(f$catalog, "a")
  expect_null(dataeuropa:::de_facets(NULL))
})

test_that("de_summarise flattens a record", {
  d <- list(id = "x", title = list(en = "T"), country = list(id = "pt"), catalog = list(id = "c"),
            distributions = list(list(format = list(id = "CSV")), list(format = list(id = "JSON")), list()),
            landing_page = list(list(resource = "http://lp")))
  s <- dataeuropa:::de_summarise(d)
  expect_equal(s$formats, "CSV,JSON")
  expect_equal(s$n_distributions, 3)
  expect_equal(s$landing_page, "http://lp")
})

test_that("de_bbox_params checks the box", {
  b <- dataeuropa:::de_bbox_params(c(20, 59.7, 31.6, 70.1))
  expect_equal(b, list(bboxMinLon = 20, bboxMinLat = 59.7, bboxMaxLon = 31.6, bboxMaxLat = 70.1))
  bad <- list(c(1, 2, 3), c(1, 2, 3, 4, 5), c("a", 1, 2, 3), c(10, 0, 5, 1), c(0, 10, 1, 5),
              c(-200, 0, 0, 1), c(0, 0, 1, 95), c(1, NA, 2, 3))
  for (x in bad) expect_error(dataeuropa:::de_bbox_params(x), "bbox")
})

skip_if(Sys.getenv("DATAEUROPA_OFFLINE") == "1", "offline")
skip_on_cran()

test_that("live search / dataset / distributions / rdf", {
  df <- de_search_datasets("water", country = "pt", format = "CSV", limit = 3)
  expect_true(nrow(df) > 0 && nrow(df) <= 3)
  expect_gt(attr(df, "count"), 0)
  id <- df$id[1]
  expect_equal(de_get_dataset(id)$summary$id, id)
  dist <- de_distributions(id)
  expect_true(nrow(dist) > 0 && "url" %in% names(dist))
  expect_match(tolower(de_get_rdf(id)), "dcat")
})

test_that("live facets, count, scroll, catalogues", {
  expect_equal(nrow(de_facet_values("country", top = 5)), 5)
  expect_gt(de_count("water", country = "de"), 0)
  x <- de_fetch_datasets("water", country = "mt", max_results = 1200, page_size = 500)
  expect_equal(length(unique(x$id)), nrow(x))
  expect_gt(nrow(x), 0)
  expect_gt(length(de_catalogues()), 100)
})

test_that("live sparql", {
  t <- de_sparql("SELECT (COUNT(?s) AS ?n) WHERE { ?s a <http://www.w3.org/ns/dcat#Dataset> }")
  expect_gt(as.numeric(t$n[1]), 1e6)
  expect_true(de_sparql("ASK { ?s ?p ?o }"))
})

test_that("live bbox filters", {
  total <- de_count()
  n <- de_count(bbox = c(20, 59.7, 31.6, 70.1))
  expect_gt(n, 0)
  expect_lt(n, total)
})
