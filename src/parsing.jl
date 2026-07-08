# The CSV-cell parsing machinery shared by the two gateway submodules (VerifyRectifications and
# VerifyRuns): lenient per-cell parsers, the issue-accumulating field setter, and the validation
# of caller-supplied global defaults. Gateway-specific cell types (e.g. VerifyRuns' MyWindow)
# extend `mytryparse` on their own types from their own module.
module Parsing

using Dates: Dates, Second, Time, TimePeriod

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

# Trim surrounding whitespace from hand-edited CSV cells: a stray space must not turn " file.mp4"
# into a missing file, or "id " vs "id" into a missed duplicate. (The numeric and tuple/time
# parsers already tolerate surrounding whitespace.) `String(...)` (not just `strip`) because strip
# returns a SubString and the struct fields are typed `::String`, which won't accept a SubString.
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

# Validate and normalize caller-supplied global defaults against a gateway's whitelist: only keys
# of `defaults` may be set, each value must convert to its column's type (`types`), and `what`
# names the kwarg in the error message ("rectification"/"tracking"). Fails fast, before any
# parsing; values are otherwise not pre-checked — an out-of-range default flows into the normal
# verifications and is flagged on every row that used it.
function resolve_defaults(overrides, defaults, types, what)
    unknown = setdiff(keys(overrides), keys(defaults))
    isempty(unknown) || throw(ArgumentError("unknown $what default(s): $(join(unknown, ", ")) (settable: $(join(keys(defaults), ", ")))"))
    isempty(overrides) && return defaults
    converted = NamedTuple{keys(overrides)}(map(keys(overrides)) do k
        try
            convert(types[k], overrides[k])
        catch
            throw(ArgumentError("$what default $k must be convertible to $(types[k]), got $(repr(overrides[k]))"))
        end
    end)
    return merge(defaults, converted)
end

end # module Parsing
