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
#
# CSV gets the bytes, not the path: a path source is memory-mapped, and the mapping outlives this
# call — `CSV.Rows` is lazy and holds it until the object is collected. On Windows a mapped file
# cannot be reopened for writing, so the iterate-on-your-csv loop (edit calibs.csv, run again in the
# same session) fails with "Invalid argument" (#133). These files are one row per run; reading them
# whole costs nothing.
function read_rows(file, columns, what)
    isfile(file) || error("$what `.csv` file missing")
    rows = CSV.Rows(read(file))
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
# Flagged rows are skipped, as in every other second-tier stage: a row that is already rejected —
# for a quarantined identity (#122), or anything else — has nothing to gain from the read, and on a
# share a read is the expensive part.
function read_per_file!(df::AbstractDataFrame, filecol, groupcols, desc, read, apply!; progress = true)
    usable = subset(dropmissing(df, groupcols; view = true), :issues => ByRow(isempty); view = true)
    groups = collect(groupby(usable, groupcols))
    metas = @showprogress desc = desc enabled = progress tmap(g -> read(g[1, filecol]), groups)
    for (g, meta) in zip(groups, metas)
        apply!(g, meta)
    end
    return df
end

# Both csvs carry an id that becomes a file name — `results_dir/<run_id>.csv` and the diagnostic
# segments, `rectifications/<calibration_id>.jpg` — so both have to be usable as one. Checked in the
# gateway, where every other cell is already checked, rather than left to fail at write time: a
# `run_id` of "2026/03/14" would otherwise surface as a SystemError out of `save2csv`, after every
# run had already been tracked.
#
# The set is what Windows forbids plus the POSIX separator, which is the union both platforms have
# to satisfy — the same reason the time-stamped issue folders carry no colons (#86). An apostrophe is
# deliberately NOT here: it is a legal file-name character, and the one place it used to break (the
# ffmpeg concat list) escapes it properly now.
const BAD_ID_CHARS = ('/', '\\', ':', '*', '?', '"', '<', '>', '|')

# Returns the fault as a predicate phrase ("contains …"), or `nothing`. A missing or blank id is
# already reported by the parser, so it is passed over rather than reported twice.
function id_filename_issue(id)
    (ismissing(id) || isempty(id)) && return nothing
    i = findfirst(c -> c in BAD_ID_CHARS || iscntrl(c), id)
    isnothing(i) || return "contains $(repr(id[i])), which cannot appear in a file name"
    id in (".", "..") && return "is $(repr(id)), which cannot be a file name"
    return nothing
end

# Flag every row whose `idcol` could not be written to disk. The id is left as it is: the row now
# carries an issue, so nothing downstream builds anything from it, and nulling the column would
# only cost the grouping that reports it.
function verify_id_filename!(df::AbstractDataFrame, idcol)
    for r in eachrow(df)
        issue = id_filename_issue(r[idcol])
        isnothing(issue) || push!(r.issues, "$idcol $issue")
    end
    return df
end

# Two csv files describe one dataset when every id one of them references exists in the other, and
# every id the other defines is actually referenced. Neither half is checkable inside a single
# gateway — the knowledge is cross-file — so it lives here, where nothing knows either domain, and
# the caller supplies the column and the two file names.
#
# `defined` owns the ids, `used` references them. Issues land on the rows carrying the offending id,
# so the per-file report names the row and the id with no extra machinery, and every second-tier
# stage skips those rows for free (they all subset to unflagged rows).
#
# A missing id is passed over rather than reported here: it is already flagged, by the parser or by
# the uniqueness check that nulled it, and it cannot be matched against anything either way.
#
# Returns whether the two files cohere, which is what the caller's first-tier gate keys on.
function verify_cross_references!(defined::AbstractDataFrame, used::AbstractDataFrame, idcol,
        defined_name, used_name)
    defined_ids = Set(skipmissing(defined[!, idcol]))
    used_ids = Set(skipmissing(used[!, idcol]))
    coherent = true
    for r in eachrow(defined)
        id = r[idcol]
        (ismissing(id) || id in used_ids) && continue
        push!(r.issues, "$idcol $id is not used by any row in $used_name — it will not be validated or built")
        coherent = false
    end
    for r in eachrow(used)
        id = r[idcol]
        (ismissing(id) || id in defined_ids) && continue
        push!(r.issues, "references $idcol $id, which is not in $defined_name — it will not be validated or built")
        coherent = false
    end
    return coherent
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
