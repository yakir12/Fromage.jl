abstract type RectificationMethod end

# The physical source video shared by every rectification method. `file` holds the resolved, canonical
# absolute path to that video (path/data_path have been folded into it and dropped during
# verification). `extrinsic` is the timestamp (seconds) of the frame each method is anchored on, and
# `aspect`/`width`/`height` are read from the video itself; `center`/`north` are optional scene points.
struct Source
    file::String
    extrinsic::Float64
    center::Union{Missing, NTuple{2, Int}}
    north::Union{Missing, NTuple{2, Int}}
    aspect::Float64
    width::Int
    height::Int
end

struct Scale <: RectificationMethod
    source::Source
    calibration_id::String
    scale::Float64
end

# `matlab_file` is the `.mat` holding the calibration matrices — a separate file from the source
# video carried in `source`.
struct MATLAB <: RectificationMethod
    source::Source
    calibration_id::String
    matlab_file::String
    extrinsic_index::Int
end

# An AprilTag rectification: the drone footage is registered to a shared reference frame (built from
# the `extrinsic` frame, where ≥ `apriltags` tags of `family` must be detectable and coplanar) rather
# than to a fixed image→real map. `tag_cell_width` is the size of one tag CELL; the black-border
# square is `cells_across(family) × tag_cell_width` (see PawsomeTracker.canon_square). It is NOT the
# `checker_width` of a video calibration (a checkerboard square) — the two were one column until
# v0.1.57 and are now separate, so each can carry its own default and each row says which it means.
# `center`/`north` live in `source` and gauge the metric output exactly as for the other methods.
struct Apriltag <: RectificationMethod
    source::Source
    calibration_id::String
    apriltags::Int
    family::String
    tag_cell_width::Float64
end

struct Video{S <: Union{Missing, Float64}} <: RectificationMethod
    source::Source
    calibration_id::String
    start::S
    stop::S
    checker_width::Float64
    n_corners::NTuple{2, Int}
    temporal_step::Float64
    radial_parameters::Int
    blur::Float64
    yadif::Bool
end

source(row) = Source(row.file, row.extrinsic, row.center, row.north, row.aspect, row.width, row.height)

RectificationMethod(row) = if row.type == "video"
    Video(source(row), row.calibration_id, row.start, row.stop, row.checker_width,
        row.n_corners, row.temporal_step, row.radial_parameters, row.blur, row.yadif)
elseif row.type == "only_scale"
    Scale(source(row), row.calibration_id, row.scale)
elseif row.type == "apriltag"
    Apriltag(source(row), row.calibration_id, row.apriltags, row.family, row.tag_cell_width)
else # can only be matlab
    MATLAB(source(row), row.calibration_id, row.matlab_file, row.extrinsic_index)
end

# `Rectification(c; rectification_diagnostics)` turns one verified calibs row into its image ↔ real
# map pair. Which builder runs is chosen by the row's type, which the parser already decided — not
# by how many arguments get passed, and every argument travels by name. That matters here more than
# it usually does: `width`/`height`, `start`/`stop` and `center`/`north` are same-typed neighbours,
# so a transposition would produce a silently wrong map rather than an error.
#
# `rectification_diagnostics` is a REQUIRED keyword, here and on every builder below. These methods
# used to take `kwargs...` and splat it onward, which had two costs: a misspelled keyword vanished
# without a word (silently, in the AprilTag case, which forwards nothing), and the builders each
# carried their own `= false` — a second definition of a value the caller always supplies. Required
# and named means it cannot be forgotten, cannot be mistyped, and is defined in exactly one place:
# `main`'s own signature.

# The six facts every builder needs from the shared `Source` (`calibration_id`, which names the
# diagnostic image, lives on the method itself and is passed alongside). `aspect` is not among them
# only because it is spelled `c.source.aspect` at each call below; every builder needs it, the
# AprilTag one included — its metric scale comes from the tags, but its `center`/`north` are still
# display pixels that have to be converted like everyone else's (#130).
_source(s::Source) = (; s.file, s.extrinsic, s.center, s.north, s.width, s.height)

Rectification(c::Video; rectification_diagnostics::Bool) =
    from_video(; _source(c.source)..., c.calibration_id, c.source.aspect, c.start, c.stop,
        c.temporal_step, c.yadif, c.blur, c.n_corners, c.checker_width, c.radial_parameters,
        rectification_diagnostics)

# A Video without a calibs window (both bounds blank ⇒ Video{Missing}) is an extrinsics-only
# rectification: the pose and focal length come from the single extrinsic frame and lens aberrations
# are disregarded. temporal_step/radial_parameters play no role and are deliberately NOT flagged
# when filled anyway (see the `from_extrinsic` docstring); only one bound filled is still an error
# (verify_pair).
Rectification(c::Video{Missing}; rectification_diagnostics::Bool) =
    from_extrinsic(; _source(c.source)..., c.calibration_id, c.source.aspect, c.yadif, c.blur,
        c.n_corners, c.checker_width, rectification_diagnostics)

# A MATLAB rectification reads the camera model (intrinsics, distortion, and the pose picked by
# extrinsic_index) from the .mat file; the source video supplies the frame size (already
# cross-checked against the .mat's ImageSize) and the extrinsic timestamp for the diagnostics.
Rectification(c::MATLAB; rectification_diagnostics::Bool) =
    from_matlab(; _source(c.source)..., c.calibration_id, c.source.aspect, c.matlab_file,
        c.extrinsic_index, rectification_diagnostics)

Rectification(c::Scale; rectification_diagnostics::Bool) =
    from_scale(; _source(c.source)..., c.calibration_id, c.source.aspect, c.scale,
        rectification_diagnostics)

# An AprilTag rectification builds its shared reference from the extrinsic frame (detecting the tags
# and fitting the metric map) and carries the centre/north gauge. There is no diagnostic image to
# render at build time — the top-down diagnostic is produced per-run during tracking — so
# `rectification_diagnostics` is accepted and deliberately not forwarded.
#
# Accepted EXPLICITLY rather than swallowed by a `kwargs...`: this method used to take one and
# discard whatever arrived, so `rectification_diagnostics = true` was a silent no-op here and a
# misspelled keyword was silent everywhere. Naming the single argument it ignores makes anything
# else a MethodError.
Rectification(c::Apriltag; rectification_diagnostics::Bool) =
    ApriltagRectification(; _source(c.source)..., c.source.aspect, ntags = c.apriltags, c.family,
        c.tag_cell_width)

