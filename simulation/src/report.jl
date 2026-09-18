# The long-format report (#294): one row per rig × rung × builder × quantity × split × statistic.
# A quantity that could not be measured keeps its rows, with no value and a `status` saying why, so
# every rig reports the same rows whatever failed.

using Printf: Format, format
using Statistics: median

"""
One row of the report.

- `section`: `"self-check"` (the simulation checking itself), `"fromage"` (Fromage on the rendered
  video) or `"control"` (Fromage on analytic corners, which separates detector error from model error).
- `builder`: `from_checkerboard` or `from_extrinsic`; `missing` for what no single builder owns.
- `aggregate`: `median`, `min` or `max` over the noisy control's seeds; `missing` elsewhere.
- `status`: `ok`, `not detected`, or `threw: <message>` with the exception's text verbatim.
- `passed`: whether a self-check passed; `missing` for everything else.
"""
const Row = @NamedTuple{
    rig::String, rung::String, builder::Union{Missing, String}, section::String,
    quantity::String, split::Union{Missing, String}, statistic::String,
    aggregate::Union{Missing, String}, value::Union{Missing, Float64}, unit::String,
    status::String, passed::Union{Missing, Bool},
}

"""
    Failure(status)

Why a quantity has no value: `"not detected"`, or `"threw: <message>"`.
"""
struct Failure
    status::String
end

value_of(x) = x
value_of(::Failure) = missing
status_of(_) = "ok"
status_of(f::Failure) = f.status
# whether a self-check's `x` is under its tolerance; one with nothing to check has failed
passes(x, tolerance) = x < tolerance
passes(::Failure, _) = false

"""
    attempt(f) -> Union{result of f, Failure}

`f()`, or the [`Failure`](@ref) recording what it threw, the exception's text verbatim. An
interrupt is not a failure of the rig, and is rethrown.

It catches everything else on purpose, against the package's rule of catching the specific
exception: the report exists to record how Fromage fails under a rig, and a failure nobody
anticipated is the one it most needs to keep (#294, "a failure becomes a `status` row"). As with
cleanup (`DECISIONS.md`, "No bare `catch`", "Cleanup inverts the rule"), nothing is lost: the report
keeps the message, and the log keeps the backtrace.
"""
function attempt(f)
    try
        return f()
    catch e
        e isa InterruptException && rethrow()
        @warn "recorded as a failure in the report" exception = (e, catch_backtrace())
        return Failure("threw: " * sprint(showerror, e))
    end
end

# `ctx` holds the columns a group of rows shares (`rig`, `rung`, `builder`, `section`)
function row(ctx; quantity, split = missing, statistic, value, unit, aggregate = missing, status = "ok", passed = missing)
    return Row((; ctx..., quantity, split, statistic, aggregate, value, unit, status, passed))
end

# RMS / p95 / max of the errors `e`, or no value and why
function stat_rows(ctx, quantity, split, unit, e)
    return [row(ctx; quantity, split, statistic = String(s), value = v, unit) for (s, v) in pairs(summarize(e))]
end
function stat_rows(ctx, quantity, split, unit, f::Failure)
    return [row(ctx; quantity, split, statistic = String(s), value = missing, unit, status = f.status) for s in STATISTICS]
end

"""
    aggregate_seeds(runs::AbstractVector{<:AbstractVector{Row}}) -> Vector{Row}

The rows of several seeds of one control, which share their layout row for row, as the median, the
min and the max of each value over the seeds. A row any seed could not measure has no value, and
the first such seed's status.
"""
function aggregate_seeds(runs)
    out = Row[]
    for i in eachindex(first(runs))
        rs = [run[i] for run in runs]
        failed = findfirst(r -> r.status != "ok", rs)
        vs = [r.value for r in rs]
        for (name, f) in (("median", median), ("min", minimum), ("max", maximum))
            r = first(rs)
            value, status = failed === nothing ? (f(vs), "ok") : (missing, rs[failed].status)
            push!(out, Row((; r..., aggregate = name, value, status)))
        end
    end
    return out
end

"""
    print_summary(io, rows)

The printed table of the primary quantities: per rig, the frames detected, the self-checks, and
the map error in mm per builder and section, each split as RMS / max.
"""
function print_summary(io::IO, rows)
    for rig in unique(r.rig for r in rows)
        rs = filter(r -> r.rig == rig, rows)
        println(io, "\n", rig)
        failed = filter(r -> r.quantity == "rig", rs)
        if !isempty(failed)
            println(io, "  ", only(failed).status)
            continue
        end
        detected = only(r for r in rs if r.quantity == "detection" && r.split == "all")
        println(io, "  frames detected: ", fmt(detected.value, "%.0f"), " of ", length(filter(r -> r.quantity == "detection", rs)) - 1)
        missed = [r.split for r in rs if r.quantity == "detection" && r.split != "all" && r.value == 0]
        isempty(missed) || println(io, "  missed: ", join(missed, ", "))
        checks = filter(r -> r.section == "self-check" && r.passed !== missing, rs)
        println(io, "  self-checks: ", join(("$(r.quantity) ($(r.split)) $(r.passed ? "ok" : "FAILED")" for r in checks), ", "))
        println(io, "  map error (mm)                         arena RMS / max    on board          off board         Procrustes")
        for section in ("fromage", "control"), builder in ("from_checkerboard", "from_extrinsic")
            m = filter(rs) do r
                r.section == section && isequal(r.builder, builder) && r.quantity == "map" &&
                    coalesce(r.aggregate, "median") == "median"
            end
            isempty(m) && continue
            cell(split) = join((fmt(only(r for r in m if r.split == split && r.statistic == s).value, "%7.3f") for s in ("RMS", "max")), " / ")
            label = section == "control" ? "$builder, analytic" : builder
            status = first(m).status == "ok" ? "" : "  " * first(m).status
            println(io, "  ", rpad(label, 36), join((cell(s) for s in MAP_SPLITS), "  "), status)
        end
    end
    return
end

fmt(::Missing, _) = "—"
fmt(v, f) = format(Format(f), v)
