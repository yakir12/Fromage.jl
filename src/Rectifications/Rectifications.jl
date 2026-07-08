module Rectifications

using ColorTypes: Gray
using CoordinateTransformations: AffineMap, IdentityTransformation, LinearMap, PerspectiveMap, Translation
using FFMPEG: FFMPEG
using FileIO: FileIO
using ImageCore: colorview, normedview
using ImageIO: ImageIO       # never used by name: loaded for FileIO's image backend (diagnostic JPEG)
using ImageTransformations: warp
using LinearAlgebra: I, norm, ⋅
using OhMyThreads: tmap
using OpenCV: OpenCV
using Polynomials: Polynomial, roots
using Rotations: Angle2d, RotationVec
using StaticArrays: SDiagonal, SVector, pop, push

const CRITERIA = OpenCV.TermCriteria(OpenCV.TERM_CRITERIA_EPS + OpenCV.TERM_CRITERIA_MAX_ITER, 30, 0.001)

# Global limiter on concurrent ffmpeg reads, shared by every `_frame_at` call (and thus by
# VerifyCalibrations, which reads through `Rectifications.get_corners`). Bounds simultaneous
# opens against the (CIFS/network) share so a burst of nested `tmap` tasks can't trip EAGAIN
# ("Resource temporarily unavailable"). A single global limiter is what composes across the
# nested tmaps — per-call `ntasks` limits would multiply. Tune via `set_read_limit!` or the
# `RECTIFICATIONS_READ_LIMIT` env var (read at `__init__`).
const READ_SEM = Ref{Base.Semaphore}()
set_read_limit!(n::Integer) = (READ_SEM[] = Base.Semaphore(n); Int(n))
read_limit() = READ_SEM[].sem_size

# ffmpeg/ffprobe commands are built by interpolating the *called* `FFMPEG.ffmpeg()` /
# `FFMPEG.ffprobe()` (the non-do-block form): each returns a `Cmd` with the absolute executable
# path and the adjusted `PATH`/`LD_LIBRARY_PATH` baked in via `setenv`, and that env survives
# interpolation into the surrounding `Cmd`. Unlike the deprecated `ffmpeg() do ... end` form it
# never mutates the process-global `ENV`, so it composes safely under the nested `tmap`
# concurrency — no snapshot, no `addenv`, no env race (which previously grew `LD_LIBRARY_PATH`
# without bound until a spawn died with E2BIG). See `_cmd` / `_probe`.

function __init__()
    # Concurrency is bounded only by the share itself; benchmarks against the CIFS mount plateau
    # around 12-24 concurrent reads (vs ~6 here historically).
    set_read_limit!(parse(Int, get(ENV, "RECTIFICATIONS_READ_LIMIT", "12")))
end

include("detect_fit.jl")
include("center_north.jl")
include("from_scale.jl")
include("from_video.jl")
include("plotting.jl")

export Rectification

end
