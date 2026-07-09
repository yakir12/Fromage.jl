# A verified run: everything `PawsomeTracker.track` needs, guaranteed not to error. A run's arity —
# a single video, or several segment videos sharing a `run_id` — is materialized in the *type* so
# `track` dispatches on it with no runtime branch, and grouping yields a `Vector{Run}` of the right
# concrete types directly. Identity lives on the concrete run types themselves (the convention
# shared with VerifyRectifications, whose method types carry `calibration_id`): `run_id` names the
# run, and `calibration_id` names the rectification this run uses (Fromage joins runs to
# rectifications on it — so a run without one has nothing to rectify against); neither is
# forwarded to `track`. The run-level *values* shared by both arities live in `Source`: the
# `track` parameters (`target_width`…`scale`) and the video's stored-pixel `width`/`height` plus
# sample aspect ratio `sar` as probed by ffprobe (segments of a multi-segment run are verified to
# agree on them; display width = `width × sar`). The per-segment fields stay in the concrete run
# types: `SingleRun` carries scalars; `MultiRun` carries aligned per-segment vectors (one entry
# per segment, in CSV order), where a non-first segment's `start_location` may be `missing` (the
# target continues from where the previous segment ended). `stop`/`fps` are concrete (imputed from
# the probed video); `window_size` stays `missing` when the CSV omitted it, and `track(::Run)`
# imputes it (impute_window_size) from `target_width`/`fps`/duration.
abstract type Run end

struct Source
    target_width::Float64
    window_size::Union{Missing, Int, NTuple{2, Int}}
    darker_target::Bool
    fps::Float64
    initial_search_factor::Float64
    white_point::Float64
    scale::Float64
    width::Int
    height::Int
    sar::Rational{Int}
end

struct SingleRun <: Run
    run_id::String
    calibration_id::String
    source::Source
    file::String
    start::Float64
    stop::Float64
    start_location::Union{Missing, NTuple{2, Int}}
end

struct MultiRun <: Run
    run_id::String
    calibration_id::String
    source::Source
    files::Vector{String}
    starts::Vector{Float64}
    stops::Vector{Float64}
    start_locations::Vector{Union{Missing, NTuple{2, Int}}}
end

# The run-level values are read off the group's first row (verify_run_consistency! guaranteed the
# segments agree on them — :dimension/:sar included). :dimension is the ffprobe-filled
# (width, height) in stored pixels; :sar the sample aspect ratio (display width = width × sar).
function Source(g::AbstractDataFrame)
    width, height = g.dimension[1]
    Source(g.target_width[1], g.window_size[1], g.darker_target[1],
        g.fps[1], g.initial_search_factor[1], g.white_point[1], g.scale[1],
        width, height, g.sar[1])
end

# Build the typed run for one `run_id` group (rows in CSV order): one row → `SingleRun` (scalar
# fields), several → `MultiRun` (aligned per-segment vectors). The type is decided here, once, from
# the group size. The identity columns are read off the first row (verify_run_consistency!
# guaranteed the segments agree on :calibration_id). The `collect(T, …)` narrows the per-segment
# columns from the `allowmissing!`-widened `Union{Missing, T}` back to `T` — safe because only
# issue-free rows reach here — and materializes the group's column views into owned vectors.
function Run(g::AbstractDataFrame)
    source = Source(g)
    if nrow(g) == 1
        SingleRun(g.run_id[1], g.calibration_id[1], source, g.file[1], g.start[1], g.stop[1], g.start_location[1])
    else
        MultiRun(g.run_id[1], g.calibration_id[1], source,
                 collect(String, g.file),
                 collect(Float64, g.start),
                 collect(Float64, g.stop),
                 Vector{Union{Missing, NTuple{2, Int}}}(g.start_location))
    end
end

# The run-level keywords shared by both `track` methods (`window_size` is imputed separately, by
# impute_window_size).
function shared_kw(r::Run)
    s = r.source
    (; s.target_width, s.darker_target, s.fps, s.initial_search_factor, s.white_point, s.scale)
end

# Drive `PawsomeTracker.track` from a verified run — the scalar method for a one-segment `SingleRun`,
# the vector method for a multi-segment `MultiRun`. Concrete-type dispatch, no runtime length check.
# The returned coordinates are (row, col) in *stored*-frame pixels of the original (unscaled) video;
# for an anamorphic video the display-space x is col × sar.
# The run's (or first segment's) start_location falls back to `center` (e.g. the rectification's scene
# center) and then to the frame's center — (x, y) in *display* pixels, matching start_location's
# convention, so x is half the display width, width × sar (`track` maps x back to stored columns) —
# so `track` always gets a concrete starting point. `center` defaults to `missing` (not `nothing`):
# coalesce only skips `missing`, so a `nothing` would leak through to `track` as-is.
frame_center(r::Run) = (round(Int, r.source.width * r.source.sar / 2), r.source.height ÷ 2)

get_sigma(target_width) = target_width / 2sqrt(2log(2))

function get_window(target_width, fps, m, duration)
    σ = get_sigma(target_width)
    ws1 = 4ceil(Int, σ) + 1 # calculates the default window size

    speed = m/duration # pixels per second
    distance = speed / fps # distance traveled per frame
    ws2 = round(Int, 2distance)

    max(ws1, ws2)
end

get_duration(r::SingleRun) = r.stop - r.start
get_duration(r::MultiRun) = mapreduce(-, +, r.stops, r.starts)

function impute_window_size(r)
    s = r.source
    return @coalesce s.window_size get_window(s.target_width, s.fps, min(s.height, s.width), get_duration(r))
end

# For an AprilTag run the calibration's `center` is a pixel in the (moved) extrinsic frame, not the
# run frame, so it can't seed the tracker's start: fall straight back to the run's own start_location
# (a missing one becomes the frame-centre search inside `track`). Every other rectification shares the
# run frame, so its centre is a valid start fallback.
function track(r::SingleRun; center = missing, rectification = nothing, kwargs...)
    start_location = if rectification isa ApriltagRectification
        r.start_location
    else
        @coalesce r.start_location center frame_center(r)
    end
    track(r.file; start = r.start, stop = r.stop, start_location, window_size = impute_window_size(r), shared_kw(r)..., rectification, kwargs...)
end

function impute_start_location(r::MultiRun, center)
    sls = r.start_locations
    sls[1] = @coalesce r.start_locations[1] center frame_center(r)
    return sls
end

function track(r::MultiRun; center = missing, rectification = nothing, kwargs...)
    # AprilTag: use the per-segment start_locations as-is (see the SingleRun note); each segment
    # relocates on its own. Other rectifications keep the centre fallback for the first segment.
    sls = rectification isa ApriltagRectification ? r.start_locations : impute_start_location(r, center)
    track(r.files; start = r.starts, stop = r.stops, start_location = sls, window_size = impute_window_size(r), shared_kw(r)..., rectification, kwargs...)
end

