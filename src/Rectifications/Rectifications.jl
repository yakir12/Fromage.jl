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

include("detect_fit.jl")
include("center_north.jl")
include("from_scale.jl")
include("from_video.jl")
include("from_matlab.jl")
include("plotting.jl")

"""
    Rectification(c; rectification_diagnostics)

The image ↔ real map pair for one verified calibration `c`, chosen by `c`'s type. The methods live
in `VerifyRectifications`, which owns those types; each reads `c`'s fields and calls one of the
builders here — `from_video`, `from_extrinsic`, `from_matlab`, `from_scale` — or
`PawsomeTracker.ApriltagRectification`, by keyword. Declared here because this module owns the
concept and `Fromage` reaches for the name through it.
"""
function Rectification end

export Rectification

end
