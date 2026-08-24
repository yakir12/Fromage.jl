# A verified run: everything `PawsomeTracker.track` needs, guaranteed not to error. A run is one or
# more segment videos sharing a `run_id`, held as a vector of `PawsomeTracker.Segment` in CSV order
# — a single-video run being the one-element case.
#
# `run_id` names the run and `calibration_id` names the rectification it uses (Fromage joins the two
# on it, so a run without one has nothing to rectify against); neither is forwarded to `track`.
#
# The run-level `track` parameters live in `tuning`, a `PawsomeTracker.Tuning` built here — which is
# to say every one of them is concrete by the time a `Run` exists. `stop`/`fps` were imputed from
# the probed video during verification; `window_size` is imputed here, from `target_width`/`fps`/
# the frame size/the run's duration. `track` itself imputes nothing and defaults nothing.
#
# `frame` holds what the video reports and the tracker does not take: the stored-pixel
# `width`/`height` and the sample aspect ratio `sar` (display width = `width × sar`), which the
# segments of a multi-segment run are verified to agree on. It is used to place a start location,
# not to track.
#
# One concrete type, not an abstract `Run` over `SingleRun`/`MultiRun`: a run's arity is data, not a
# kind of thing. See DESIGN-HISTORY.md for what the split cost and what it turned out not to buy.

struct Frame
    width::Int
    height::Int
    sar::Rational{Int}
end

struct Run
    run_id::String
    calibration_id::String
    tuning::Tuning
    frame::Frame
    segments::Vector{Segment}
end

# The run's total tracked span, over which the default window size estimates the target's speed.
run_duration(segments) = sum(s -> s.stop - s.start, segments)

# The run-level values are read off the group's first row (verify_run_consistency! guaranteed the
# segments agree on them — :dimension/:sar included). :dimension is the ffprobe-filled
# (width, height) in stored pixels.
#
# :video_fps is the exception: it is NOT in SHARED_PARAMS, so segments are not required to agree on
# it (see runs.md, #95). The first row's is what `track` used anyway — it read the rate from the
# first file — so carrying it here changes nothing except that the video is no longer reopened for
# it.
#
# `window_size` is imputed here rather than left blank for `track` to fill: a blank csv cell means
# "use the default", and this is where that default is applied, once.
function _tuning(g::AbstractDataFrame, frame::Frame, segments::Vector{Segment})
    target_width = g.target_width[1]
    fps = g.fps[1]
    window_size = @coalesce g.window_size[1] get_window(target_width, fps,
        min(frame.height, frame.width), run_duration(segments))
    return Tuning(target_width, window_size, g.darker_target[1], fps, g.video_fps[1],
        g.initial_search_factor[1], g.scale[1], g.background_length[1])
end

# Build the run for one `run_id` group (rows in CSV order, one row per segment). The identity
# columns are read off the first row, which verify_run_consistency! guaranteed the segments agree
# on. The per-segment columns come out of the `allowmissing!`-widened `Union{Missing, T}` columns
# and are narrowed by `Segment`'s own field types — safe because only issue-free rows reach here.
function Run(g::AbstractDataFrame)
    width, height = g.dimension[1]
    frame = Frame(width, height, g.sar[1])
    segments = Segment[Segment(f, a, o, sl)
                       for (f, a, o, sl) in zip(g.file, g.start, g.stop, g.start_location)]
    return Run(g.run_id[1], g.calibration_id[1], _tuning(g, frame, segments), frame, segments)
end

# The run's (or first segment's) start_location falls back to `center` (e.g. the rectification's
# scene centre) and then to the frame's centre, so `track` always gets a concrete starting point.
# Both are (x, y) in *display* pixels, matching start_location's convention, so x is half of
# width × sar and `track` maps it back to stored columns.
frame_center(f::Frame) = (round(Int, f.width * f.sar / 2), f.height ÷ 2)

# The run's segments with the first one's start-location fallbacks applied, ready for `track`.
#
# For an AprilTag run the calibration's `center` is a pixel in the (moved) extrinsic frame, not the
# run frame, so it can't seed the tracker's start: the per-segment start_locations are used as-is, a
# missing one becoming the frame-centre search inside `track`, and each segment relocates on its
# own. Every other rectification shares the run frame, so its centre is a valid fallback for the
# first segment.
#
# `center` defaults to nothing here only through its callers; it arrives as `missing` when absent,
# because coalesce only skips `missing`.
#
# The `copy` is what makes this a query rather than an edit: a `Run` describes what the csv said,
# and tracking it must leave it alone (#23).
function resolved_segments(r::Run, center, rectification)
    rectification isa ApriltagRectification && return r.segments
    out = copy(r.segments)
    s = out[1]
    out[1] = Segment(s.file, s.start, s.stop,
                     @coalesce s.start_location center frame_center(r.frame))
    return out
end

# Drive `PawsomeTracker.track` from a verified run. Positional, like `track` itself: a `Run` already
# holds every tuning value, so the only things left to say are which scene centre to fall back on,
# what to rectify through, and where the diagnostic goes.
#
# The returned coordinates are (row, col) in *stored*-frame pixels of the original (unscaled) video;
# for an anamorphic video the display-space x is col × sar.
track(r::Run, center, rectification, diagnostic_file) =
    track(resolved_segments(r, center, rectification), r.tuning, rectification, diagnostic_file)
