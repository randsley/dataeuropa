module DataEuropaParquet2Ext

using DataEuropa, DataFrames, Parquet2

# Read from bytes in memory: given a path, Parquet2 memory-maps the file, which keeps it locked
# on Windows and stops the temporary download from being deleted.
DataEuropa._read_parquet(path) = DataFrame(Parquet2.Dataset(read(path)); copycols=true)

end
