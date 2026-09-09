# The module's vocabulary: what a caller hands `track`, and the two derived forms `track` builds
# from it. In its own file, and included FIRST, because `track_one` and `track_apriltag` name these
# types in their signatures — and a signature's annotations are evaluated when the method is
# defined, so the types have to exist before `apriltag.jl` is included. The same reason both
# gateways keep a `types.jl`.

"""
    Segment(file, start, stop, start_location)

One video of a run: the file, the seconds into it at which tracking starts and stops, and where the
target is at `start`, as an `(x, y)` display-pixel position.

`start_location` is `missing` on any segment whose starting position is not known independently —
the second and later segments of an ordinary run, where the target continues from where the
previous one ended, and any segment of an AprilTag run, where a missing one becomes a frame-centre
search. The first segment of an ordinary run carries a concrete one: the runs gateway resolves it
(csv cell, then the rectification's `center`, then the frame centre) before building the segment.

The union is exactly what is supported (#18). `RowCol` is absent on purpose despite having a
`get_guess` method: that is the internal form a later segment's start takes, carried over from the
previous segment's last coordinate, not something a caller supplies.
"""
struct Segment
    file::String
    start::Float64
    stop::Float64
    start_location::Union{Missing, NTuple{2, Int}}

    # `start_location` is ASSERTED by this constructor, not converted. Julia converts struct fields
    # on assignment, and Base can convert a `CartesianIndex{2}` to an `NTuple{2, Int}` — so without
    # the annotation here a (row, col) CartesianIndex would become an (x, y) start location with its
    # axes silently swapped. That is a worse version of the bug #18 was filed about (a type the
    # signature advertised but `get_guess` could not handle), and the reason the union names only
    # what `get_guess` has a method for. The other three fields convert as usual.
    Segment(file, start, stop, start_location::Union{Missing, NTuple{2, Int}}) =
        new(file, start, stop, start_location)
end

"""
    ResolvedSegment(file, start, stop, start_location)

A `Segment` whose starting point has been settled, which is what a tracking function actually takes.

The difference from `Segment` is the union: this one also admits `RowCol`, the internal form a later
segment's start takes when it is carried over from the previous segment's last coordinate. A
`Segment` cannot hold that — its constructor asserts `Union{Missing, NTuple{2, Int}}` on purpose
(#18) — so the chained value had to travel as a loose argument alongside the segment it belonged to.
Here the union names **exactly** the three types `get_guess` has a method for, and nothing else.

Built by `track`, and **only on the ordinary path**: the gateway resolves the *first* segment's
start (`VerifyRuns.resolved_segments`, csv cell → the rectification's `center` → the frame centre),
and the chaining in `track` resolves the rest.

`track_apriltag` takes a plain `Segment` instead, because AprilTag segments do not chain
(DECISIONS.md) — nothing there can produce a `RowCol` start, and `apriltag_guess` has no method for
one. Handing it this wider type would advertise a case no method handles, which is what #18 was
about; JET reports it as an unmatched union split. So the two types are not interchangeable, and
which one a tracking function takes says whether its path chains.
"""
struct ResolvedSegment
    file::String
    start::Float64
    stop::Float64
    start_location::Union{Missing, NTuple{2, Int}, RowCol}

    # Asserted, not converted, for the same reason `Segment`'s is: a `CartesianIndex{2}` converts
    # silently to an `NTuple{2, Int}` and would arrive as an (x, y) start location with its axes
    # swapped.
    ResolvedSegment(file, start, stop, start_location::Union{Missing, NTuple{2, Int}, RowCol}) =
        new(file, start, stop, start_location)
end

"""
    Tuning(target_width, window_size, darker_target, sample_fps, native_fps,
           initial_search_factor, downscale, background_length)

The run-level tracking parameters, every one of them concrete.

Deliberately without defaults, and `track` deliberately takes no keyword arguments: each of these
values is decided in exactly one place — a csv cell, `VerifyRuns.DEFAULTS`, or the gateway's probe
of the video — and giving them a second definition here is what let a global default and a verified
value disagree, and what let an unverified value reach the tracker at all (#140, #141). A caller
with no gateway behind it (the test suite) builds one explicitly; see `tuning` in
`test/fixtures.jl`.

`window_size` is the search window scanned around the target's last known position, already imputed
(`get_window`) rather than left blank — so there is one imputation rule, upstream, instead of a
second one here.

The two rates are separate parameters and neither is derived from the other here. `native_fps` is
the rate the video itself runs at — probed once by the gateway, or declared in `runs.csv` when the
container reports it wrongly — and `sample_fps` the rate to sample it at, which the gateway has
verified does not exceed it. Both arrive concrete: tracking never opens a video merely to ask what
rate it runs at (see WHY-FRAMES-FAIL.md), and never re-derives a rate it was given.
"""
struct Tuning
    target_width::Float64
    window_size::Union{Int, NTuple{2, Int}}
    darker_target::Bool
    sample_fps::Float64
    native_fps::Float64
    initial_search_factor::Float64
    downscale::Float64
    background_length::Int
end

"""
    ScaledTuning(tuning)

The three `Tuning` values pre-scaled by `downscale`, computed once per run rather than per segment.

- `width` is the target's width in scaled pixels, which sizes the DoG sigma.
- `window` is the search window as scaled `(rows, cols)` — `fix_window_size` has already turned the
  csv's display `(width, height)` into that order.
- `search` is the scaled initial search factor, used only when a segment has no `start_location`
  and the tracker falls back to a centre search.

**Not** `Tuning` fields under new values: the names differ from the csv columns
(`target_width`/`window_size`/`initial_search_factor`) precisely because these are *derived*, and a
field named `target_width` holding `downscale × target_width` would be the same quiet lie as a
`RowCol` holding `(x, y)`. That is also why this type is deliberately absent from the
one-definition-site invariant in `test/quality.jl`: the rule there is that every tracking
*parameter* is a `runs.csv` column, and none of these three is a parameter.
"""
struct ScaledTuning
    width::Float64
    window::NTuple{2, Int}
    search::Float64
end
ScaledTuning(t::Tuning) = ScaledTuning(t.downscale * t.target_width,
                                       round.(Int, t.downscale .* fix_window_size(t.window_size)),
                                       t.downscale * t.initial_search_factor)
