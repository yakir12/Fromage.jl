# Local parse helper mirroring Base.tryparse semantics (returns the parsed value or `nothing` on
# failure). Defining our own avoids type piracy on Base.tryparse for types we don't own (String,
# NTuple). The generic fallback delegates to Base for the standard types (Int, Float64, Bool, ...).
mytryparse(::Type{T}, x) where {T} = tryparse(T, x)

function mytryparse(::Type{NTuple{2, Int}}, s)
    m = match(r"^\s*[\(\[]?\s*(-?\d+)\s*,\s*(-?\d+)\s*[\)\]]?\s*$", s)
    isnothing(m) && return nothing
    a = tryparse(Int, m.captures[1])      # tryparse (not parse): a > Int64 value overflows ->
    b = tryparse(Int, m.captures[2])      # nothing -> "wrong format" issue, not an uncaught throw
    (isnothing(a) || isnothing(b)) && return nothing
    return (a, b)
end

tosecond(x::T) where {T <: TimePeriod} = Float64(x / convert(T, Second(1)))
tosecond(x::Time) = tosecond(x - Time(0))

# A temporal cell: either a plain number of seconds ("9", "12.5") or a clock time ("00:01:30").
struct MyTemporal end
function mytryparse(::Type{MyTemporal}, x)
    seconds = tryparse(Float64, x)
    isnothing(seconds) || return seconds
    time = tryparse(Time, x)
    isnothing(time) || return tosecond(time)
    return nothing
end

# `window_size` accepts either a single side length ("31") or a (width, height) pair ("(31, 41)").
# Try the scalar first, then fall back to the tuple parser.
struct MyWindow end
function mytryparse(::Type{MyWindow}, s)
    i = tryparse(Int, strip(string(s)))
    isnothing(i) || return i
    return mytryparse(NTuple{2, Int}, s)
end

# Trim surrounding whitespace from hand-edited CSV cells: a stray space must not turn " file.mp4" into
# a missing file, or "id " vs "id" into a missed duplicate. (The numeric and tuple/time parsers already
# tolerate surrounding whitespace.) `String(...)` (not just `strip`) because strip returns a SubString
# and the struct fields are typed `::String`, which won't accept a SubString.
mytryparse(::Type{String}, x) = String(strip(string(x)))

function set!(dict, y, k, _)
    dict[k] = y
end

function set!(dict, ::Nothing, k, msg)
    dict[k] = missing
    push!(dict[:issues], msg)
end

function parseto!(dict, row, k, ::Type{T}, default = nothing) where {T}
    raw = haskey(row, k) ? row[k] : missing
    # A present-but-blank cell (whitespace only) is treated exactly like an absent one: a required
    # field then reports "is missing" instead of silently becoming an empty string, and an optional
    # field falls back to its default.
    if !ismissing(raw) && !(raw isa AbstractString && isempty(strip(raw)))
        y = mytryparse(T, raw)
        set!(dict, y, k, "wrong $k format")
    else
        set!(dict, default, k, "$k is missing")
    end
end

# Every column maps to one `track` keyword (plus `run_id`/`path` for identity & path resolution).
# Defaults mirror `PawsomeTracker.track`'s own defaults so a blank cell behaves exactly as omitting the
# argument would. `stop`/`fps` are left missing here and imputed from the probed video (duration /
# framerate); `window_size`/`start_location` stay missing and are simply omitted from the `track` call.
function parse_run!(dict, row)
    parseto!(dict, row, :run_id, String, missing)               # all-or-nothing: blank only allowed when every row is blank (then imputed from the row number); see resolve_run_ids!
    parseto!(dict, row, :calibration_id, String)                # required: Fromage joins runs to calibrations on it
    parseto!(dict, row, :file, String)
    parseto!(dict, row, :path, String, ".")
    parseto!(dict, row, :start, MyTemporal, 0.0)
    parseto!(dict, row, :stop, MyTemporal, missing)              # imputed from video duration
    parseto!(dict, row, :target_width, Float64, 25.0)
    parseto!(dict, row, :start_location, NTuple{2, Int}, missing)
    parseto!(dict, row, :window_size, MyWindow, missing)
    parseto!(dict, row, :darker_target, Bool, true)
    parseto!(dict, row, :fps, Float64, missing)                  # imputed from video framerate
    parseto!(dict, row, :apriltags, Int, 0)
    parseto!(dict, row, :initial_search_factor, Float64, 4.0)
    parseto!(dict, row, :white_point, Float64, 1.0)
    parseto!(dict, row, :scale, Float64, 1.0)
end

function parse_row(row)
    dict = Dict{Symbol, Any}(:issues => String[])
    parse_run!(dict, row)
    for col in COLUMNS
        haskey(dict, col) || (dict[col] = missing)
    end
    return dict
end

# run_id is all-or-nothing: either every row names its run (enabling multi-segment runs), or no
# row does (column absent, or present with every cell blank) and each row becomes its own
# single-segment run, identified by its 1-based row number. A mixed file is rejected — under
# partial numbering a blank row's auto-generated id could silently merge with an explicit one
# (e.g. "3") into a bogus multi-segment run, so there is no safe way to honor it. In the mixed
# case the blanks stay missing: Run construction only happens on the issue-free path, and
# verify_run_consistency! skips missing-id groups.
function resolve_run_ids!(df)
    if all(ismissing, df.run_id)
        df.run_id = string.(1:nrow(df))
    elseif any(ismissing, df.run_id)
        rows = findall(ismissing, df.run_id)
        push!.(df.issues[rows], "run_id is missing (either every row has a run_id or none does)")
    end
    return df
end
