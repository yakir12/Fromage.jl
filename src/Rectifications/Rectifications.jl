module Rectifications

using ColorTypes: Gray
using CoordinateTransformations: AffineMap, IdentityTransformation, LinearMap, PerspectiveMap, Translation
using ..Paths: RECTIFICATIONS_DIR
using ..ShareIO: ShareIO
using FFMPEG: FFMPEG
using FileIO: FileIO
using ImageCore: colorview, normedview
using ImageIO: ImageIO       # never used by name: loaded for FileIO's image backend (diagnostic JPEG)
using ImageTransformations: warp
using LinearAlgebra: I, norm, ⋅
using MAT: matread
using OhMyThreads: tmap
using OpenCV: OpenCV
using Polynomials: Polynomial, roots
using Rotations: Angle2d, RotationVec
using StaticArrays: SDiagonal, SVector, pop, push

const CRITERIA = OpenCV.TermCriteria(OpenCV.TERM_CRITERIA_EPS + OpenCV.TERM_CRITERIA_MAX_ITER, 30, 0.001)

# ffmpeg/ffprobe commands are built by interpolating the *called* `FFMPEG.ffmpeg()` /
# `FFMPEG.ffprobe()` (the non-do-block form): each returns a `Cmd` with the absolute executable
# path and the adjusted `PATH`/`LD_LIBRARY_PATH` baked in via `setenv`, and that env survives
# interpolation into the surrounding `Cmd` without ever touching the process-global `ENV` — which
# is what makes it safe under the nested `tmap` concurrency. See `_cmd`.

"""
    StaticRectification(image2real, real2image, ratio, width, height)

One calibration's fixed image ↔ real map pair, as `from_checkerboard`, `from_extrinsic`,
`from_matlab` and `from_uniform` return it. "Static" is the contrast with `PawsomeTracker.ApriltagRectification`: the
camera does not move, so a single pair of maps describes the whole run, where the AprilTag path
re-registers every frame against a shared reference.

- `image2real` maps pixel `(row, col)` to real-world units; `real2image` is its inverse.
- `ratio` is real-world units per pixel at the arena centre, which sizes the diagnostic warp.
- `width`, `height` are the source video's frame size in pixels, as probed.

A struct rather than the `(; image2real, real2image, ratio, width, height)` NamedTuple the builders
used to return: that shape was written out three times and had to stay in step by hand, which is
the same one-definition-site argument as #140/#141. It also gives the exported concept a name that
can be dispatched on and documented — previously `Rectification` was a function with no type behind
it, so no signature could say "a rectification".
"""
struct StaticRectification{I, R}
    image2real::I
    real2image::R
    ratio::Float64
    width::Int
    height::Int
end

include("detect_fit.jl")
include("center_north.jl")
include("from_uniform.jl")
include("from_checkerboard.jl")
include("from_matlab.jl")
include("plotting.jl")

"""
    Rectification(c; rectification_diagnostics)

The image ↔ real map pair for one verified calibration `c`, chosen by `c`'s type. The methods live
in `VerifyRectifications`, which owns those types; each reads `c`'s fields and calls one of the
builders here — `from_checkerboard`, `from_extrinsic`, `from_matlab`, `from_uniform` — or
`PawsomeTracker.ApriltagRectification`, by keyword. Declared here because this module owns the
concept and `Fromage` reaches for the name through it.
"""
function Rectification end

export Rectification, StaticRectification

end
