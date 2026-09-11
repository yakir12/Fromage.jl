# The conversions between the coordinate spaces. CONTEXT.md's table says what the seven spaces ARE
# and which axis order each uses; this module is how you get from one to another, and is the only
# place those rules are written down as code.
#
# It exists because they were not. `stored x = display x / sar` had four independent spellings
# (Rectifications' fix_coordinate, PawsomeTracker's get_guess, and two in apriltag.jl), and #130 was
# two of them disagreeing about which direction `sar` goes — a bug that displaced every anamorphic
# rectification by half a frame and was invisible at sar 1, which is every square fixture. The frame
# centre had two. One definition site per rule, the same argument as #140/#141 one layer down.
#
# Deliberately NOT here (see DECISIONS.md): the AprilTag path's inline (row, col) ↔ (x, y) index
# reversals, which are local to apriltag.jl's index pipe; `fix_window_size`, whose swap is fused
# with `oddify`'s documented extra-pixel behaviour; and any wrapper type that would make a
# transposition a MethodError, which is a measurement question rather than a naming one.
module Spaces

using StaticArrays: SVector

"""
    RowCol(row, col)

An alias for a static vector of two, row and column, indicating a cartesian coordinate in an
image/matrix.

The name is a convention, not an invariant. It is a bare `SVector{2, Float32}`, so nothing stops a
caller putting an `(x, y)` pair in one — and the AprilTag path does exactly that, because `track`
collects both paths' results into one array type. Where that is meant, spell it [`GroundXY`](@ref),
which is the same type under the name that is true there.
"""
const RowCol = SVector{2, Float32}

"""
    GroundXY(x, y)

Metric ground coordinates, `(x, y)`, as `track_apriltag` produces them before the centre/north gauge.

**The same type as [`RowCol`](@ref)**, not a distinct one — `track` collects the AprilTag path's
coordinates and the ordinary path's into a single array type, so these must stay
interchangeable. The alias exists so a declaration can say which of the two it means; it buys a
true name, not a check.
"""
const GroundXY = RowCol

"""
    stored_x(x, sar)

The display → stored correction on the x axis alone: `stored x = display x / sar`.

The stored frame is squeezed horizontally by the sample aspect ratio, so a coordinate a user read
off a screen has to be divided by `sar` to name the column it actually came from. This is the whole
of the anamorphic rule, and the direction is the one #130 got backwards.

`sar` is deliberately untyped beyond `Real`: `VerifyRuns` holds it as an exact `Rational{Int}`
because it bounds-checks a pixel against `width × sar`, `VerifyRectifications` as the `Float64` that
mirrors `VideoIO.aspect_ratio` (where it is spelled `aspect`), and each caller's arithmetic and
result type are preserved by not pinning either.
"""
stored_x(x::Real, sar::Real) = x / sar

"""
    to_stored(xy, sar)

Display `(x, y)` to stored `(row, col)`: [`stored_x`](@ref) on the x, and a swap.

Both halves matter and both have been wrong. `missing` passes through, because `center` and `north`
are optional and "no point" has to survive the conversion.

Everything a user writes — `center`, `north`, `start_location`, `window_size` — is display `(x, y)`,
because that is what an image viewer reports. This is the door between that and everything internal.
"""
# `::Real` on both, not a bare `_`: with `sar::Real` on the method below, an unannotated second
# argument here is not strictly more specific, and `to_stored(missing, 1.0)` is an ambiguity rather
# than a passthrough.
to_stored(::Missing, ::Real) = missing
function to_stored(xy, sar::Real)
    x, y = xy
    return (y, stored_x(x, sar))
end

"""
    display_center_x(width, sar)

The x coordinate of a frame's centre, in display pixels: the display width is `width × sar`, so the
centre is half of that.

Exact, and unrounded on purpose — its two callers round differently (`VerifyRuns.frame_center`
truncates to an `Int` start location, `Rectifications.default_center` keeps the `Float64` half) and
this returns the value they disagree about rather than picking for them.
"""
display_center_x(width::Real, sar::Real) = width * sar / 2

end # module Spaces
