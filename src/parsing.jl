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

# An exact ratio: "4/3", ffprobe's own "4:3", or a plain number ("2", "0.5", "1.333"). A decimal is
# taken as exactly the decimal written (`rationalize` returns the simplest ratio within `eps` of it,
# so "0.5" is 1//2 and "1.333" is 1333//1000, not 4//3). A zero denominator, a non-finite decimal, or
# one too large for an `Int` ratio is a wrong format; the sign is left for the caller's range check.
function mytryparse(::Type{Rational{Int}}, x)
    s = strip(string(x))
    m = match(r"^(-?\d+)\s*[/:]\s*(\d+)$", s)
    if !isnothing(m)
        num = tryparse(Int, m.captures[1])
        den = tryparse(Int, m.captures[2])
        (isnothing(num) || isnothing(den) || iszero(den)) && return nothing
        return num // den
    end
    d = tryparse(Float64, s)
    (isnothing(d) || !isfinite(d)) && return nothing
    r = rationalize(Int, d)
    # past `typemax(Int)` there is no nearer ratio than `1//0`, which would pass a `> 0` check
    return iszero(denominator(r)) ? nothing : r
end

tosecond(x::T) where {T <: TimePeriod} = Float64(x / convert(T, Second(1)))
tosecond(x::Time) = tosecond(x - Time(0))

# A temporal cell: either a plain number of seconds ("9", "12.5") or a clock time ("00:01:30").
#
# Trimmed here rather than relying on the parsers: `tryparse(Float64, …)` skips surrounding
# whitespace and `tryparse(Time, …)` does not, so " 00:01:30 " fell through both branches and was
# reported as "wrong start format" while " 12.5 " — the same cell written as a number, with the
# same stray spaces — parsed fine. `Time` is the only cell type Base leaves untrimmed.
struct MyTemporal end
function mytryparse(::Type{MyTemporal}, x)
    s = strip(string(x))
    seconds = tryparse(Float64, s)
    isnothing(seconds) || return seconds
    time = tryparse(Time, s)
    isnothing(time) || return tosecond(time)
    return nothing
end

# Trim surrounding whitespace from hand-edited CSV cells; the numeric and tuple parsers tolerate it
# already, and `MyTemporal` trims for itself because Base's `Time` parser does not. `String(...)`
# and not just `strip`, whose SubString the `::String` fields won't accept.
mytryparse(::Type{String}, x) = String(strip(string(x)))

# Base's float parser accepts "NaN", "Inf" and "-Inf" (in any case) as well-formed, and nothing
# downstream is prepared for them: a NaN target_width surfaced as `InexactError: Int64(NaN)` inside
# tracking (#151). Every parsed cell passes through `set!`, so this is where a non-finite one is
# refused — as a report naming the column and the value, not a throw. Only a float can be
# non-finite; the integer, tuple and Bool parsers reject "NaN" as a wrong format on their own.
nonfinite(x::AbstractFloat) = !isfinite(x)
nonfinite(_) = false

function set!(dict, y, k, _)
    nonfinite(y) && return set!(dict, nothing, k, "$k must be finite, got $y")
    return dict[k] = y
end

function set!(dict, ::Nothing, k, msg)
    dict[k] = missing
    return push!(dict[:issues], msg)
end

# Does the csv actually say something in this cell? A present-but-blank cell (whitespace only)
# counts as absent: a required field reports "is missing" rather than becoming an empty string, and
# an optional one takes its default. Shared, so anything asking "did the user fill this in?" asks it
# the same way the parser did — see VerifyRectifications' verify_pair.
filled(row, k) = haskey(row, k) && !ismissing(row[k]) &&
    !(row[k] isa AbstractString && isempty(strip(row[k])))

# The `default` a required cell passes: an absent one is reported as "is missing" rather than
# filled in (see `set!`'s `::Nothing` method). Named so a call site says "required" rather than a
# bare `nothing`; there is no default argument doing it silently (#273).
const REQUIRED = nothing

function parseto!(dict, row, k, ::Type{T}, default) where {T}
    return if filled(row, k)
        y = mytryparse(T, row[k])
        set!(dict, y, k, "wrong $k format")
    else
        set!(dict, default, k, "$k is missing")
    end
end

# Validate and normalize caller-supplied global defaults against a gateway's whitelist: only keys
# of `defaults` may be set, each value must convert to its column's type (`types`), and `what`
# names the kwarg in the error message ("rectification"/"tracking"). Fails fast, before any
# parsing. A non-finite float converts cleanly, so it is refused separately, on the same terms as a
# csv cell (see `nonfinite`). Values are not otherwise pre-checked: an out-of-range default flows
# into the normal verifications and is flagged on every row that used it.
function resolve_defaults(overrides, defaults, types, what)
    unknown = setdiff(keys(overrides), keys(defaults))
    isempty(unknown) || throw(ArgumentError("unknown $what default(s): $(join(unknown, ", ")) (settable: $(join(keys(defaults), ", ")))"))
    isempty(overrides) && return defaults
    # `convert` has no non-throwing counterpart, so this stays a caught exception — but only the two
    # a rejected value can raise over the whitelisted types: `MethodError` (no such conversion:
    # "yes" -> Bool) or `InexactError` (a lossy one: 1.5 -> Int). Anything else propagates.
    converted = NamedTuple{keys(overrides)}(
        map(keys(overrides)) do k
            v = try
                convert(types[k], overrides[k])
            catch e
                e isa MethodError || e isa InexactError || rethrow()
                throw(ArgumentError("$what default $k must be convertible to $(types[k]), got $(repr(overrides[k]))"))
            end
            nonfinite(v) && throw(ArgumentError("$what default $k must be finite, got $(repr(overrides[k]))"))
            v
        end
    )
    return merge(defaults, converted)
end

end # module Parsing
