# WHAT A RUN IS
#
# One repeat of an experiment. Experiments answer scientific questions through repetition, and each
# repeat is a run: one trial, one animal crossing the arena once. A run is an event in the world,
# not a file — Fromage meets it twice, as the `runs.csv` rows that describe it and as the TRACK it
# yields.
#
# A run may be split across several video files (the camera divided one recording), and each piece
# is a SEGMENT. They are one run because they share a `run_id`. Three consequences follow, and each
# is enforced somewhere below: one timeline (`_concat_timestamps` — the segments' timestamps are one
# clock), one set of run-level parameters (`verify_run_consistency!`), and one track file
# (`save2csv` writes `<run_id>.csv`).
#
# The word is NOT used for an execution of Fromage — that is a SESSION (see `session_issues_dir` in
# paths.jl) — and not for the track itself, which `main` returns in a column called `track`.
#
# A verified run: everything `PawsomeTracker.track` needs, guaranteed not to error. It is held as a
# vector of `PawsomeTracker.Segment` in CSV order, a single-video run being the one-element case.
#
# `run_id` names the run and `rectification_id` names the rectification it uses (Fromage joins the two
# on it, so a run without one has nothing to rectify against); neither is forwarded to `track`.
#
# The run-level `track` parameters live in `tuning`, a `PawsomeTracker.Tuning` built here — which is
# to say every one of them is concrete by the time a `Run` exists. `stop` and the two rates were
# imputed during verification (`stop` and `native_fps` from the probed video, `sample_fps` from
# `native_fps`); `window_size` is imputed here, from `target_width`/`sample_fps`/the frame size/the
# run's duration. `track` itself imputes nothing and defaults nothing.
#
# `frame_format` holds what the video reports and the tracker does not take: the stored-pixel
# `width`/`height` and the sample aspect ratio `sar` (display width = `width × sar`), which the
# segments of a multi-segment run are verified to agree on. It is used to place a start location,
# not to track.
#
# One concrete type, not an abstract `Run` over `SingleRun`/`MultiRun`: a run's segment count is
# data, not a kind of thing. See DECISIONS.md for what the split cost and what it turned out not to
# buy.

struct FrameFormat
    width::Int
    height::Int
    sar::Rational{Int}
end

struct Run
    run_id::String
    rectification_id::String
    tuning::Tuning
    frame_format::FrameFormat
    segments::Vector{Segment}
end

# The run's total tracked span, over which the default window size estimates the target's speed.
run_duration(segments) = sum(s -> s.stop - s.start, segments)

# The run-level values are read off the group's first row (verify_run_consistency! guaranteed the
# segments agree on them — :dimension/:sar included). :dimension is the ffprobe-filled
# (width, height) in stored pixels.
#
# There is no exception left: `native_fps` is a run-level parameter like any other here, spread
# across the run's rows when declared and compared across them when imputed, so the first row's is
# the run's by construction. It used to be probed-only and unshared (#95) — and `track` read the
# rate from the file all over again, which is what made a declared one impossible.
#
# `window_size` is imputed here rather than left blank for `track` to fill: a blank csv cell means
# "use the default", and this is where that default is applied, once.
function _tuning(g::AbstractDataFrame, frame_format::FrameFormat, segments::Vector{Segment})
    target_width = g.target_width[1]
    sample_fps = g.sample_fps[1]
    window_size = @coalesce g.window_size[1] get_window(target_width, sample_fps,
        min(frame_format.height, frame_format.width), run_duration(segments))
    return Tuning(target_width, window_size, g.darker_target[1], sample_fps, g.native_fps[1],
        g.initial_search_factor[1], g.downscale[1], g.background_length[1])
end

# Build the run for one `run_id` group (rows in CSV order, one row per segment). The identity
# columns are read off the first row, which verify_run_consistency! guaranteed the segments agree
# on. The per-segment columns come out of the `allowmissing!`-widened `Union{Missing, T}` columns
# and are narrowed by `Segment`'s own field types — safe because only issue-free rows reach here.
function Run(g::AbstractDataFrame)
    width, height = g.dimension[1]
    frame_format = FrameFormat(width, height, g.sar[1])
    segments = Segment[Segment(f, a, o, sl)
                       for (f, a, o, sl) in zip(g.file, g.start, g.stop, g.start_location)]
    return Run(g.run_id[1], g.rectification_id[1], _tuning(g, frame_format, segments), frame_format, segments)
end

# The run's (or first segment's) start_location falls back to `center` (e.g. the rectification's
# scene centre) and then to the frame's centre, so `track` always gets a concrete starting point.
# Both are (x, y) in *display* pixels, matching start_location's convention, so x is half of
# width × sar (`Spaces.display_center_x`) and `track` maps it back to stored columns.
#
# The rounding is deliberately spelled here rather than shared: a start location is an Int pixel, so
# the x rounds and the y truncates, where `Rectifications.default_center` — the other caller of
# `display_center_x`, computing the same centre — keeps exact Float64 halves. The two differ by up
# to half a pixel on an odd height, which is not obviously right and is not this function's to fix.
frame_center(f::FrameFormat) = (round(Int, display_center_x(f.width, f.sar)), f.height ÷ 2)

# The run's segments with the first one's start-location fallbacks applied, ready for `track`.
#
# For an AprilTag run the rectification's `center` is a pixel in the (moved) extrinsic frame, not in
# the RUN SPACE, so it can't seed the tracker's start: the per-segment start_locations are used as-is, a
# missing one becoming the frame-centre search inside `track`, and each segment relocates on its
# own. Every other rectification shares the run space, so its centre is a valid fallback for the
# first segment.
#
# `center` defaults to nothing here only through its callers; it arrives as `missing` when absent,
# because coalesce only skips `missing`.
#
# The `copy` is what makes this a query rather than an edit: a `Run` describes what the csv said,
# and tracking it must leave it alone (#23).
# AprilTag mode carries every segment's own start_location through untouched: segments do not chain
# there (DECISIONS), so there is nothing to impute. Selected by the rectification's TYPE rather
# than by an `isa` inside the general method.
resolved_segments(r::Run, _, ::ApriltagRectification) = r.segments

function resolved_segments(r::Run, center, rectification)
    out = copy(r.segments)
    s = out[1]
    out[1] = Segment(s.file, s.start, s.stop,
                     @coalesce s.start_location center frame_center(r.frame_format))
    return out
end

# Drive `PawsomeTracker.track` from a verified run. Positional, like `track` itself: a `Run` already
# holds every tuning value, so the only things left to say are which scene centre to fall back on,
# what to rectify through, and where the diagnostic goes.
#
# The returned coordinates are (row, col) in *stored* pixels of the original (unscaled) video;
# for an anamorphic video the display-space x is col × sar.
track(r::Run, center, rectification, diagnostic_file) =
    track(resolved_segments(r, center, rectification), r.tuning, rectification, diagnostic_file)
