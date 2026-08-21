# A verified run: everything `PawsomeTracker.track` needs, guaranteed not to error. A run is one or
# more segment videos sharing a `run_id`, held as aligned per-segment vectors in CSV order — a
# single-video run being the one-element case. A non-first segment's `start_location` may be
# `missing` (the target continues from where the previous one ended).
#
# `run_id` names the run and `calibration_id` names the rectification it uses (Fromage joins the two
# on it, so a run without one has nothing to rectify against); neither is forwarded to `track`. The
# run-level values live in `Source`: the `track` parameters (`target_width`…`scale`) plus the
# video's stored-pixel `width`/`height` and sample aspect ratio `sar` as probed by ffprobe, which
# the segments of a multi-segment run are verified to agree on (display width = `width × sar`).
#
# `stop`/`fps` are concrete, imputed from the probed video. `window_size` stays `missing` when the
# CSV omitted it, and `track(::Run)` imputes it from `target_width`/`fps`/duration.
#
# One concrete type, not an abstract `Run` over `SingleRun`/`MultiRun`: a run's arity is data, not a
# kind of thing. See DESIGN-HISTORY.md for what the split cost and what it turned out not to buy.

struct Source
    target_width::Float64
    window_size::Union{Missing, Int, NTuple{2, Int}}
    darker_target::Bool
    fps::Float64
    video_fps::Float64
    initial_search_factor::Float64
    scale::Float64
    background_length::Int
    width::Int
    height::Int
    sar::Rational{Int}
end

struct Run
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
#
# :video_fps is the exception: it is NOT in SHARED_PARAMS, so segments are not required to agree on
# it (see runs.md, #95). The first row's is what `track` used anyway — it read the rate from
# `files[1]` — so carrying it here changes nothing except that the video is no longer reopened for
# it.
function Source(g::AbstractDataFrame)
    width, height = g.dimension[1]
    Source(g.target_width[1], g.window_size[1], g.darker_target[1],
        g.fps[1], g.video_fps[1], g.initial_search_factor[1], g.scale[1],
        g.background_length[1], width, height, g.sar[1])
end

# Build the run for one `run_id` group (rows in CSV order, one row per segment). The identity
# columns are read off the first row, which verify_run_consistency! guaranteed the segments agree
# on. The `collect(T, …)` narrows the per-segment columns from the `allowmissing!`-widened
# `Union{Missing, T}` back to `T` — safe because only issue-free rows reach here — and materializes
# the group's column views into owned vectors.
function Run(g::AbstractDataFrame)
    Run(g.run_id[1], g.calibration_id[1], Source(g),
        collect(String, g.file),
        collect(Float64, g.start),
        collect(Float64, g.stop),
        Vector{Union{Missing, NTuple{2, Int}}}(g.start_location))
end

# The run-level keywords forwarded to `track` (`window_size` is imputed separately, by
# impute_window_size).
function shared_kw(r::Run)
    s = r.source
    (; s.target_width, s.darker_target, s.fps, s.video_fps, s.initial_search_factor, s.scale,
        s.background_length)
end

# Drive `PawsomeTracker.track` from a verified run. The returned coordinates are (row, col) in
# *stored*-frame pixels of the original (unscaled) video; for an anamorphic video the display-space
# x is col × sar.
#
# The run's (or first segment's) start_location falls back to `center` (e.g. the rectification's
# scene centre) and then to the frame's centre, so `track` always gets a concrete starting point.
# Both are (x, y) in *display* pixels, matching start_location's convention, so x is half of
# width × sar and `track` maps it back to stored columns. `center` defaults to `missing` rather than
# `nothing` because coalesce only skips `missing`.
frame_center(r::Run) = (round(Int, r.source.width * r.source.sar / 2), r.source.height ÷ 2)

function get_window(target_width, fps, m, duration)
    σ = get_sigma(target_width)
    ws1 = 4ceil(Int, σ) + 1 # calculates the default window size

    speed = m/duration # pixels per second
    distance = speed / fps # distance traveled per frame
    ws2 = round(Int, 2distance)

    max(ws1, ws2)
end

get_duration(r::Run) = mapreduce(-, +, r.stops, r.starts)

function impute_window_size(r)
    s = r.source
    return @coalesce s.window_size get_window(s.target_width, s.fps, min(s.height, s.width), get_duration(r))
end

# The per-segment start locations with the first segment's fallbacks applied, as a vector `track`
# can take. The `copy` is what makes this a query rather than an edit: a `Run` describes what the
# csv said, and tracking it must leave it alone (#23).
function impute_start_location(r::Run, center)
    sls = copy(r.start_locations)
    sls[1] = @coalesce sls[1] center frame_center(r)
    return sls
end

# For an AprilTag run the calibration's `center` is a pixel in the (moved) extrinsic frame, not the
# run frame, so it can't seed the tracker's start: the per-segment start_locations are used as-is,
# a missing one becoming the frame-centre search inside `track`, and each segment relocates on its
# own. Every other rectification shares the run frame, so its centre is a valid fallback for the
# first segment.
function track(r::Run; center = missing, rectification = nothing, kwargs...)
    sls = rectification isa ApriltagRectification ? r.start_locations : impute_start_location(r, center)
    track(r.files; start = r.starts, stop = r.stops, start_location = sls,
        window_size = impute_window_size(r), shared_kw(r)..., rectification, kwargs...)
end

