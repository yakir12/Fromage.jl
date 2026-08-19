# The CSV side of the two gateway suites: build a row against a suite's column header, write the
# rows out, run the loader, and say what it flagged. Only the gateway suites need any of this.
#
# Everything here takes what it needs as an argument. The suite-specific half — the header, the
# loader call, the baseline rows, what a clean result looks like — stays in each suite's
# `helpers.jl`, where it is short enough to read at a glance.
module Harness

using DataFrames: AbstractDataFrame

export csvcell, write_csv, buildrow, flagged, capturing

csvcell(::Missing) = ""
function csvcell(x)
    s = x isa AbstractString ? String(x) : string(x)
    (occursin(',', s) || occursin('"', s)) ? string('"', replace(s, '"' => "\"\""), '"') : s
end

function write_csv(path, rows, header)
    open(path, "w") do io
        println(io, join(header, ","))
        for r in rows
            println(io, join(csvcell.(r), ","))
        end
    end
    path
end

# A kwarg not in `header` would be dropped silently, quietly testing nothing.
function buildrow(header; kw...)
    unknown = setdiff(string.(keys(kw)), header)
    @assert isempty(unknown) "unknown CSV column/s in test row: $unknown"
    return [get(kw, Symbol(c), missing) for c in header]
end

# A load with issues returns a DataFrame carrying :issues (non-strict); a clean one returns the
# built objects, so anything that isn't a DataFrame is unflagged by definition.
flagged(x, r, sub) = x isa AbstractDataFrame && any(m -> occursin(sub, m), x.issues[r])

"Run `f`, returning (its result, what it printed to stdout). Routed through a temp file because
redirect_stdout needs a real file descriptor, not an IOBuffer."
function capturing(f)
    mktemp() do path, io
        result = redirect_stdout(f, io)
        flush(io)
        result, read(path, String)
    end
end

end
