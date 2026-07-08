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

# The globally overridable defaults: exactly the tracking tuning parameters — not identities
# (`run_id`/`calibration_id`/`file`/`path`) and not the temporal window (`start`/`stop`/
# `start_location`), which are inherently per-row. The caller replaces any of these via
# `load_runs`' `defaults` kwarg (in Fromage: `main`'s `tracking_defaults`); a csv cell always
# wins over the replaced default (see parseto!). `fps = missing` means "imputed from the probed
# video", so a caller-supplied fps beats the probe on every row whose cell is blank.
const DEFAULTS = (;
    target_width = 25.0,
    window_size = missing,
    darker_target = true,
    fps = missing,
    apriltags = 0,
    initial_search_factor = 4.0,
    white_point = 1.0,
    scale = 1.0,
)

const DEFAULT_TYPES = (;
    target_width = Float64,
    window_size = Union{Int, NTuple{2, Int}},
    darker_target = Bool,
    fps = Float64,
    apriltags = Int,
    initial_search_factor = Float64,
    white_point = Float64,
    scale = Float64,
)

# Validate and normalize the caller's overrides, failing fast (before any parsing): only the
# whitelisted keys above may be set, and each value must convert to its column's type. Values are
# otherwise not pre-checked — an out-of-range default flows into the normal verifications and is
# flagged on every row that used it.
function resolve_defaults(overrides)
    unknown = setdiff(keys(overrides), keys(DEFAULTS))
    isempty(unknown) || throw(ArgumentError("unknown tracking default(s): $(join(unknown, ", ")) (settable: $(join(keys(DEFAULTS), ", ")))"))
    isempty(overrides) && return DEFAULTS
    converted = NamedTuple{keys(overrides)}(map(keys(overrides)) do k
        try
            convert(DEFAULT_TYPES[k], overrides[k])
        catch
            throw(ArgumentError("tracking default $k must be convertible to $(DEFAULT_TYPES[k]), got $(repr(overrides[k]))"))
        end
    end)
    return merge(DEFAULTS, converted)
end

# Every column maps to one `track` keyword (plus `run_id`/`path` for identity & path resolution).
# The hardcoded defaults (see DEFAULTS) mirror `PawsomeTracker.track`'s own so a blank cell behaves
# exactly as omitting the argument would. `stop`/`fps` are left missing here and imputed from the
# probed video (duration / framerate); `window_size`/`start_location` stay missing and are simply
# omitted from the `track` call.
function parse_run!(dict, row, defaults)
    parseto!(dict, row, :run_id, String, missing)               # all-or-nothing: blank only allowed when every row is blank (then imputed from the row number); see resolve_run_ids!
    parseto!(dict, row, :calibration_id, String)                # required: Fromage joins runs to rectifications on it
    parseto!(dict, row, :file, String)
    parseto!(dict, row, :path, String, ".")
    parseto!(dict, row, :start, MyTemporal, 0.0)
    parseto!(dict, row, :stop, MyTemporal, missing)              # imputed from video duration
    parseto!(dict, row, :target_width, Float64, defaults.target_width)
    parseto!(dict, row, :start_location, NTuple{2, Int}, missing)
    parseto!(dict, row, :window_size, MyWindow, defaults.window_size)
    parseto!(dict, row, :darker_target, Bool, defaults.darker_target)
    parseto!(dict, row, :fps, Float64, defaults.fps)             # imputed from video framerate when missing
    parseto!(dict, row, :apriltags, Int, defaults.apriltags)
    parseto!(dict, row, :initial_search_factor, Float64, defaults.initial_search_factor)
    parseto!(dict, row, :white_point, Float64, defaults.white_point)
    parseto!(dict, row, :scale, Float64, defaults.scale)
end

function parse_row(row, defaults = DEFAULTS)
    dict = Dict{Symbol, Any}(:issues => String[])
    parse_run!(dict, row, defaults)
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
