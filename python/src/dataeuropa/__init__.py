"""dataeuropa: access the data.europa.eu open data portal (Search API, Registry, SPARQL)."""
from .client import (SEARCH_URL, REPO_URL, SPARQL_URL, catalogues, count, distributions, download,
                     facet_values, fetch_datasets, get_dataset, get_rdf, iter_datasets, pick_lang,
                     search, search_datasets, sparql, summarise_dataset)

__version__ = "0.1.0"
__all__ = ["search", "search_datasets", "iter_datasets", "fetch_datasets", "get_dataset", "distributions",
           "download", "facet_values", "count", "catalogues", "get_rdf", "sparql", "pick_lang",
           "summarise_dataset"]
