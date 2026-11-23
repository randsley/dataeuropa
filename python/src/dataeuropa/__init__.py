"""dataeuropa: access the data.europa.eu open data portal (Search API, Registry, SPARQL)."""
from .client import (SEARCH_URL, REPO_URL, SPARQL_URL, cache_off, cache_on, catalogues, clear_cache, count, distributions, download,
                     facet_values, fetch_datasets, get_dataset, get_rdf, iter_datasets, load_distribution, pick_lang,
                     search, search_datasets, sparql, summarise_dataset)

__version__ = "0.1.0"
__all__ = ["search", "search_datasets", "iter_datasets", "fetch_datasets", "get_dataset", "distributions",
           "download", "load_distribution", "facet_values", "count", "catalogues", "get_rdf", "sparql", "pick_lang",
           "summarise_dataset", "cache_on", "cache_off", "clear_cache"]
