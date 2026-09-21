# The verdicts (#296): which rows of the report are worth a look. They are aids for exploring, not a
# gate: they mark rows, and pass or fail nothing.
#
# Two families per rig × rung × builder. `total` judges the rows from the detected corners against
# the replicates; `model` judges the analytic-corner controls against the baseline's controls, so a
# `model` flag means Fromage's model cannot represent the physics, whatever the detector does.
#
# Each row is judged by how far it lies above the baseline's level, in floors (#312): a systematic
# error the baseline already has, such as `from_extrinsic`'s ~2.7 mm, is the level to compare
# against, not a floor to multiply. A row better than the baseline is never flagged.

"""
    Rule(over, tolerance, flag)

A row is flagged `flag` (`"serious"` or `"diagnostic"`) when its magnitude exceeds its baseline
level by more than `over` floors, and exceeds `tolerance`; `tolerance` is `missing` for a quantity
with no physical scale, which the ratio alone decides.
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

# the baseline `Level` row `r` is judged against, in its family's floors; `missing` outside both
# families, and for a quantity the baseline has no value of
function level_of(floors::Floors, r)
    r.section == "fromage" && return get(floors.total, floor_key(r), missing)
    r.section == "control" && return get(floors.model, floor_key(r), missing)
    return missing
end

"""
The columns a row's verdict adds to the report (#296, #312):

- `level`: the baseline's typical magnitude of it (see [`Floors`](@ref)), `missing` where there is none;
- `floor`: how far that magnitude moves across the baseline's replicates;
- `ratio`: how far its value's magnitude is above `level`, in floors — negative below it;
- `tolerance`: the absolute bound a flagged value must also exceed, in the row's unit;
- `family`: `total` (rows from the detected corners) or `model` (the analytic-corner controls);
- `verdict`: `ok`, `diagnostic`, `serious`, or `n/a` for a row that is not judged or has no value.
"""
const Verdict = @NamedTuple{
    level::Union{Missing, Float64}, floor::Union{Missing, Float64}, ratio::Union{Missing, Float64},
    tolerance::Union{Missing, Float64},
    family::Union{Missing, String}, verdict::String,
}

"""
    judge(r, floors::Floors) -> Verdict

Row `r`'s [`Verdict`](@ref) under [`RULES`](@ref), against `floors`.
"""
function judge(r, floors::Floors)
    return verdict(rule(r), r.value, level_of(floors, r), get(FAMILIES, r.section, missing))
end

verdict(::Nothing, value, baseline, family) = Verdict((level_fields(value, baseline)..., missing, family, "n/a"))
verdict(::Missed, value, baseline, family) = Verdict((missing, missing, missing, missing, family, value < 1 ? "serious" : "ok"))
function verdict(rule::Rule, value, baseline, family)
    fields = level_fields(value, baseline)
    ismissing(fields.ratio) && return Verdict((fields..., rule.tolerance, family, "n/a"))
    flagged = fields.ratio > rule.over && (ismissing(rule.tolerance) || abs(value) > rule.tolerance)
    return Verdict((fields..., rule.tolerance, family, flagged ? rule.flag : "ok"))
end

# the `level`, `floor` and `ratio` columns of a value judged against a baseline `Level`
level_fields(value, ::Missing) = (; level = missing, floor = missing, ratio = missing)
level_fields(value, l::Level) = (; l.level, l.floor, ratio = ratio(value, l))

# how far a value's magnitude is above the level, in floors: zero at the level, even over a zero
# floor, and ±Inf off it over a zero floor
ratio(::Missing, ::Level) = missing
function ratio(value, l::Level)
    excess = abs(value) - l.level
    return iszero(excess) ? 0.0 : excess / l.floor
end

"""
    judged(rows, floors::Floors)

Each row with its [`Verdict`](@ref)'s columns after its own.
"""
judged(rows, floors::Floors) = [merge(r, judge(r, floors)) for r in rows]
