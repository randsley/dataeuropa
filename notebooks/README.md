# Notebooks

The worked examples from the documentation as Jupyter notebooks, one per language:
[Python](python.ipynb), [Julia](julia.ipynb) and [R](r.ipynb). Each runs from top to bottom
against the live portal and prints the source of the data it uses (portal id, publisher, licence,
retrieval date). They write no files.

The outputs are a stored snapshot: the portal changes all the time, so counts and search results
will differ when you run them. They are not run in CI.

## Refresh the outputs

When the portal's data changes, run each notebook again and commit the result:

```sh
cd notebooks
jupyter nbconvert --to notebook --execute --inplace python.ipynb   # needs dataeuropa[pandas,geo] and matplotlib
jupyter nbconvert --to notebook --execute --inplace r.ipynb        # needs IRkernel, dataeuropa and sf
JULIA_PROJECT=<env> jupyter nbconvert --to notebook --execute --inplace --ExecutePreprocessor.timeout=900 julia.ipynb
```

For Julia, `<env>` is an environment with DataEuropa, DataFrames and GeoDataFrames (and IJulia
in the default environment). Refresh the worked examples in the three doc sites at the same time.
