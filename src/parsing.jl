# The CSV-cell parsing machinery shared by the two gateway submodules (VerifyRectifications and
# VerifyRuns): lenient per-cell parsers, the issue-accumulating field setter, and the validation
# of caller-supplied global defaults. Gateway-specific cell types (e.g. VerifyRuns' MyWindow)
# extend `mytryparse` on their own types from their own module.
module Parsing

using Dates: Dates, Second, Time, TimePeriod

# Local parse helper mirroring Base.tryparse semantics (the parsed value, or `nothing` on failure).
# Ours, rather than Base.tryparse, to avoid type piracy on types we don't own (String, NTuple); the
# generic fallback delegates to Base for the standard types (Int, Float64, Bool, ...).
mytryparse(::Type{T}, x) where {T} = tryparse(T, x)

function mytryparse(::Type{NTuple{2, Int}}, s)
    m = match(r"^\s*[\(\[]?\s*(-?\d+)\s*,\s*(-?\d+)\s*[\)\]]?\s*$", s)
    isnothing(m) && return nothing
    a = tryparse(Int, m.captures[1])      # tryparse, not parse: an over-Int64 value becomes
    b = tryparse(Int, m.captures[2])      # `nothing` (a "wrong format" issue), not a throw
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

# Trim surrounding whitespace from hand-edited CSV cells; the numeric and tuple/time parsers
# tolerate it already. `String(...)` and not just `strip`, whose SubString the `::String` fields
# won't accept.
mytryparse(::Type{String}, x) = String(strip(string(x)))

function set!(dict, y, k, _)
    dict[k] = y
end

function set!(dict, ::Nothing, k, msg)
    dict[k] = missing
    push!(dict[:issues], msg)
end

# Does the csv actually say something in this cell? A present-but-blank cell (whitespace only)
# counts as absent: a required field reports "is missing" rather than becoming an empty string, and
# an optional one takes its default. Shared, so anything asking "did the user fill this in?" asks it
# the same way the parser did — see VerifyRectifications' verify_pair.
filled(row, k) = haskey(row, k) && !ismissing(row[k]) &&
    !(row[k] isa AbstractString && isempty(strip(row[k])))

function parseto!(dict, row, k, ::Type{T}, default = nothing) where {T}
    if filled(row, k)
        y = mytryparse(T, row[k])
        set!(dict, y, k, "wrong $k format")
    else
        set!(dict, default, k, "$k is missing")
    end
end

# Validate and normalize caller-supplied global defaults against a gateway's whitelist: only keys
# of `defaults` may be set, each value must convert to its column's type (`types`), and `what`
# names the kwarg in the error message ("rectification"/"tracking"). Fails fast, before any
# parsing. Values are not otherwise pre-checked: an out-of-range default flows into the normal
# verifications and is flagged on every row that used it.
function resolve_defaults(overrides, defaults, types, what)
    unknown = setdiff(keys(overrides), keys(defaults))
    isempty(unknown) || throw(ArgumentError("unknown $what default(s): $(join(unknown, ", ")) (settable: $(join(keys(defaults), ", ")))"))
    isempty(overrides) && return defaults
    # `convert` has no non-throwing counterpart, so this stays a caught exception — but only the two
    # a rejected value can raise over the whitelisted types: `MethodError` (no such conversion:
    # "yes" -> Bool) or `InexactError` (a lossy one: 1.5 -> Int). Anything else propagates.
    converted = NamedTuple{keys(overrides)}(map(keys(overrides)) do k
        try
            convert(types[k], overrides[k])
        catch e
            e isa MethodError || e isa InexactError || rethrow()
            throw(ArgumentError("$what default $k must be convertible to $(types[k]), got $(repr(overrides[k]))"))
        end
    end)
    return merge(defaults, converted)
end

end # module Parsing
