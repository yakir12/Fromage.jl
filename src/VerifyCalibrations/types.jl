abstract type CalibrationMethod end

# The physical source video shared by every calibration method. `file` holds the resolved, canonical
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

struct Scale <: CalibrationMethod
    source::Source
    calibration_id::String
    scale::Float64
end

# `matlab_file` is the `.mat` holding the calibration matrices — a separate file from the source
# video carried in `source`.
struct MATLAB <: CalibrationMethod
    source::Source
    calibration_id::String
    matlab_file::String
    extrinsic_index::Int
end

struct Video{S <: Union{Missing, Float64}} <: CalibrationMethod
    source::Source
    calibration_id::String
    start::S
    stop::S
    checker_size::Float64
    n_corners::NTuple{2, Int}
    temporal_step::Float64
    radial_parameters::Int
    blur::Float64
    yadif::Bool
end

source(row) = Source(row.file, row.extrinsic, row.center, row.north, row.aspect, row.width, row.height)

CalibrationMethod(row) = if row.type == "video"
    Video(source(row), row.calibration_id, row.start, row.stop, row.checker_size,
        row.n_corners, row.temporal_step, row.radial_parameters, row.blur, row.yadif)
elseif row.type == "only_scale"
    Scale(source(row), row.calibration_id, row.scale)
else # can only be matlab
    MATLAB(source(row), row.calibration_id, row.matlab_file, row.extrinsic_index)
end
Rectification(c::Video; kwargs...) = Rectification(c.source.file, c.source.extrinsic, c.start, c.stop, c.temporal_step, c.yadif, c.blur, c.source.width, c.source.height, c.n_corners, c.checker_size, c.source.aspect, c.radial_parameters, c.source.center, c.source.north; kwargs...)

# A Video without a calibs window (both bounds blank ⇒ Video{Missing}) is an extrinsics-only
# calibration: the pose and focal length come from the single extrinsic frame and lens aberrations
# are disregarded (zero distortion) — temporal_step/radial_parameters play no role and are
# deliberately NOT flagged when filled anyway (omitting both window bounds is too large an action
# to be a mistake, so it expresses intent; see the extrinsics-only Rectification docstring in
# Rectifications for the full rationale). Only one bound filled is still an error (verify_pair).
Rectification(c::Video{Missing}; kwargs...) = Rectification(c.source.file, c.source.extrinsic, c.yadif, c.blur, c.source.width, c.source.height, c.n_corners, c.checker_size, c.source.aspect, c.source.center, c.source.north; kwargs...)

# Rectification(c::MATLAB) = loadMAT(c.matlab_file; extrinsic_index = c.extrinsic_index, center = c.source.center, north = c.source.north, aspect = c.source.aspect)

Rectification(c::Scale; kwargs...) = Rectification(c.source.file, c.source.extrinsic, c.scale, c.source.aspect, c.source.center, c.source.north, c.source.width, c.source.height; kwargs...)
