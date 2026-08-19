# The plumbing both gateway submodules (VerifyRectifications and VerifyRuns) run their CSV through,
# in the order they run it: read and screen the file, resolve every path against the data folder,
# read each physical file once, flag rows that fail a check, and print what was wrong.
#
# What stays in each gateway is what actually differs — its column list, its defaults, its row
# parsers, and its checks. This module knows nothing about either domain; every message it emits is
# either passed in or built from a column name.
module Gateway

using CSV: CSV
using DataFrames: AbstractDataFrame, ByRow, Cols, Not, dropmissing, groupby, passmissing,
    select!, subset
using OhMyThreads: OhMyThreads, tmap
using ProgressMeter: ProgressMeter, @showprogress
using Tables: Tables

# Read the CSV and screen it before a single cell is parsed: the file must exist, hold at least one
# row, and name only columns the gateway recognizes. `what` names the file in the two messages that
# mention it ("runs"/"calibration"), which are the gateway's own words for its input.
function read_rows(file, columns, what)
    isfile(file) || error("$what `.csv` file missing")
    rows = CSV.Rows(file)
    isempty(Tables.rows(rows)) && error("csv file is empty")
    unrecognized = setdiff(Tables.schema(rows).names, columns)
    isempty(unrecognized) || error("unrecognized column/s in $what file: $unrecognized")
    return rows
end

# A row parser fills only the columns its type consumes; every other recognized column must still
# exist (as missing) so the rows form one rectangular DataFrame.
function backfill!(dict, columns)
    for col in columns
        haskey(dict, col) || (dict[col] = missing)
    end
    return dict
end

# Create (or blank) the intermediate columns a later step fills. They must exist up front: the
# per-file read writes into groups, which are views, and a view cannot add a column of its own.
# `[!, col]` rather than `[:, col]` so an existing concrete-typed column widens to hold `missing`.
function blank!(df::AbstractDataFrame, cols...)
    for col in cols
        df[!, col] .= missing
    end
    return df
end

# Subset the rows whose `args` trip `predicate`, null the offending field (first of `args`) so later
# checks skip them, and record `msg`. `passmissing`/`skipmissing` leave already-missing fields alone.
function verify!(df::AbstractDataFrame, predicate, msg, args...)
    bad = subset(df, Cols(args...) => ByRow(passmissing(predicate)); view = true, skipmissing = true)
    # `[!, col]` and not `[:, col]`: the field being nulled may still be a concrete-typed column, and
    # only `!` lets the assignment widen it to hold `missing`.
    bad[!, first(args)] .= missing
    push!.(bad.issues, msg)      # the vectors are the parent's; push! needs no assignment back
    return df
end

# Resolve `:path` against the data folder, check it is a folder holding each of `filecols`, then
# collapse each of those into one canonical absolute path and drop `:path`, whose job is then done.
#
# A path naming the video itself is the common slip, and must be reported as such rather than as
# "does not exist" (#33). It runs first, and `verify!` nulls `:path` on failure, so the existence
# check below skips the row rather than piling on. `realpath` is safe for the same reason —
# non-existent paths were nulled just above — and is what collapses "./x", "a/../x" and symlinks
# onto the one key that later steps group physical files by.
function resolve_paths!(df::AbstractDataFrame, data_path, filecols...)
    df.path .= passmissing(joinpath).(data_path, df.path)
    verify!(df, isfile, "path is a file, not a folder — it should be the folder holding the video, with the file name in the `file` column", :path)
    verify!(df, !isdir, "path does not exist", :path)
    for col in filecols
        # `verify!` skips missing, so a column only some row types carry (VerifyRectifications'
        # :matlab_file) leaves the rest untouched.
        verify!(df, (f, p) -> !isfile(joinpath(p, f)), "$col does not exist", col, :path)
        df[!, col] .= passmissing(joinpath).(df.path, df[!, col])
        df[!, col] .= passmissing(realpath).(df[!, col])
    end
    select!(df, Not(:path))
    return df
end

# One read per physical file, in parallel: group the rows that name one, read each group's file
# once, then fold the result back into its rows with `apply!`. Grouping on the canonical resolved
# path (see `resolve_paths!`) reads a file reached through several spellings once, not once per
# spelling. `read` returns either the metadata or an issue string, and `apply!` dispatches on which.
function read_per_file!(df::AbstractDataFrame, filecol, groupcols, desc, read, apply!)
    groups = collect(groupby(dropmissing(df, groupcols; view = true), groupcols))
    metas = @showprogress desc = desc tmap(g -> read(g[1, filecol]), groups)
    for (g, meta) in zip(groups, metas)
        apply!(g, meta)
    end
    return df
end

# Print every row's issues, one line per row, and throw under `strict`. Returns whether anything was
# wrong, so a caller can hand the raw DataFrame back instead of building its objects.
#
# `mention(i, id)` decides whether row `i`'s identity adds anything over "row $i" — an id that is
# missing, or that was auto-generated from the row number, does not.
function report_issues(df::AbstractDataFrame, idcol, csv_name, what, strict; mention)
    any(!isempty, df.issues) || return false
    ids = df[!, idcol]
    msg = join([string(mention(i, id) ? "row $i ($idcol: $id)" : "row $i", ": ", join(issues, ", "))
                for (i, (id, issues)) in enumerate(zip(ids, df.issues)) if !isempty(issues)], '\n')
    println('\n' * "The following are issues with the $csv_name file:\n" * msg)
    strict && error("there were issues with the $what (see above)")
    return true
end

end # module Gateway
