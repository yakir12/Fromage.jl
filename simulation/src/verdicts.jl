# The verdicts (#296): which rows of the report are worth a look. They are aids for exploring, not a
# gate: they mark rows, and pass or fail nothing.
#
# Two families per rig × rung × builder. `total` judges the rows from the detected corners against
# the replicate floor; `model` judges the analytic-corner controls against the baseline's control,
# so a `model` flag means Fromage's model cannot represent the physics, whatever the detector does.

"""
    Rule(over, tolerance, flag)

A row is flagged `flag` (`"serious"` or `"diagnostic"`) when its ratio to its floor exceeds `over`
and its magnitude exceeds `tolerance`; `tolerance` is `missing` for a quantity with no physical
scale, which the ratio alone decides.
"""
struct Rule
    over::Float64
    tolerance::Union{Missing, Float64}
    flag::String
end

"A frame's detection: any frame missed is serious. Detection is deterministic, so it needs no floor."
struct Missed end

"""
The rules, by section, quantity and statistic (#296). RMS and max are judged, p95 is not, so one
error is not counted three times. The tolerances (mm) were set by the user, except the `model`
family's 0.1 mm, proposed while resolving #296 and to be revisited once variant numbers exist.
"""
const RULES = Dict{Tuple{String, String, String}, Union{Rule, Missed}}(
    ("fromage", "detection", "detected") => Missed(),
    ("fromage", "map", "RMS") => Rule(3, 1.0, "serious"),
    ("fromage", "map", "max") => Rule(3, 3.0, "serious"),
    ("fromage", "dot separation", "error") => Rule(3, 1.0, "serious"),
    ("fromage", "corners", "RMS") => Rule(3, missing, "diagnostic"),
    ("fromage", "corners", "max") => Rule(3, missing, "diagnostic"),
    ("fromage", "intrinsics", "error") => Rule(3, missing, "diagnostic"),
    ("control", "map", "RMS") => Rule(10, 0.1, "serious"),
    ("control", "map", "max") => Rule(10, 0.1, "serious"),
)

"The verdict families, by the section whose rows they judge."
const FAMILIES = Dict("fromage" => "total", "control" => "model")

# The rule judging row `r`, or `nothing`. Not judged beside what `RULES` leaves out: the frames
# detected in all, as each missed frame already is; and the min and max over a control's seeds, as
# the median stands for them.
function rule(r)
    r.quantity == "detection" && r.split == "all" && return nothing
    coalesce(r.aggregate, "median") == "median" || return nothing
    return get(RULES, (r.section, r.quantity, r.statistic), nothing)
end

# the floor row `r` is judged against, in its family's floors; `missing` outside both families
function floor_of(floors::Floors, r)
    r.section == "fromage" && return get(floors.total, floor_key(r), missing)
    r.section == "control" && return get(floors.model, floor_key(r), missing)
    return missing
end

"""
The columns a row's verdict adds to the report (#296):

- `floor`: what its value is judged against (see [`Floors`](@ref)), `missing` where there is none;
- `ratio`: its value's magnitude over `floor`;
- `tolerance`: the absolute bound a flagged value must also exceed, in the row's unit;
- `family`: `total` (rows from the detected corners) or `model` (the analytic-corner controls);
- `verdict`: `ok`, `diagnostic`, `serious`, or `n/a` for a row that is not judged or has no value.
"""
const Verdict = @NamedTuple{
    floor::Union{Missing, Float64}, ratio::Union{Missing, Float64}, tolerance::Union{Missing, Float64},
    family::Union{Missing, String}, verdict::String,
}

"""
    judge(r, floors::Floors) -> Verdict

Row `r`'s [`Verdict`](@ref) under [`RULES`](@ref), against `floors`.
"""
function judge(r, floors::Floors)
    return verdict(rule(r), r.value, floor_of(floors, r), get(FAMILIES, r.section, missing))
end

verdict(::Nothing, value, floor, family) = Verdict((floor, ratio(value, floor), missing, family, "n/a"))
verdict(::Missed, value, floor, family) = Verdict((missing, missing, missing, family, value < 1 ? "serious" : "ok"))
function verdict(rule::Rule, value, floor, family)
    q = ratio(value, floor)
    ismissing(q) && return Verdict((floor, q, rule.tolerance, family, "n/a"))
    flagged = q > rule.over && (ismissing(rule.tolerance) || abs(value) > rule.tolerance)
    return Verdict((floor, q, rule.tolerance, family, flagged ? rule.flag : "ok"))
end

# a value's magnitude over its floor: zero for a zero value, even over a zero floor
ratio(::Missing, _) = missing
ratio(_, ::Missing) = missing
ratio(::Missing, ::Missing) = missing
ratio(value, floor) = iszero(value) ? 0.0 : abs(value) / floor

"""
    judged(rows, floors::Floors)

Each row with its [`Verdict`](@ref)'s columns after its own.
"""
judged(rows, floors::Floors) = [merge(r, judge(r, floors)) for r in rows]
