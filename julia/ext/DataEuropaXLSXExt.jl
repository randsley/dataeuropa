module DataEuropaXLSXExt

using DataEuropa, DataFrames, XLSX

# `sheet`: a name, a 1-based index, or `nothing` for the first sheet.
function DataEuropa._read_xlsx(path, sheet)
    names = XLSX.openxlsx(XLSX.sheetnames, path)
    name = sheet === nothing ? first(names) : sheet isa Integer ? names[sheet] : String(sheet)
    return DataFrame(XLSX.readtable(path, name; infer_eltypes=true))
end

end
