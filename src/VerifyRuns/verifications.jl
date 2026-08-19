# Probe one video file with a single ffprobe call: frame width/height (stored pixels), sample aspect
# ratio, container duration and the (real) frame rate. Returns a NamedTuple, or an "issue reading..."
# string for a corrupt/unreadable file. The spawn, its `key=value` output and the per-field parsers
# are shared with VerifyRectifications in ..Probing; what stays here is which entries this gateway
# asks for and which of them it cannot proceed without. `fps` is one of those — it imputes the run's
# tracking rate when the csv leaves it blank. `sar` has a documented square-pixel fallback, so a
# missing one is not an error.
function probe_video(file)
    fields = probe_fields(file, "stream=width,height,r_frame_rate,sample_aspect_ratio:format=duration")
    fields isa String && return fields                 # unreadable file: pass the issue straight on
    geometry = frame_geometry(fields)
    fps = parse_framerate(get(fields, "r_frame_rate", ""))
    if isnothing(geometry) || isnothing(fps)
        return no_video_stream("width/height/duration/frame rate")
    end
    return (; geometry..., fps, sar = parse_sar(get(fields, "sample_aspect_ratio", "1:1")))
end

# One ffprobe per physical video file fills the intermediate :dimension/:duration/:video_fps columns
# and imputes the two blank-able run parameters: :stop (← duration) and :fps (← video frame rate).
function read_video_metadata!(df::AbstractDataFrame)
    blank!(df, :dimension, :duration, :video_fps, :sar)
    read_per_file!(df, :file, [:file], "Reading runs videos...", probe_video, apply_video_metadata!)
end

apply_video_metadata!(g, issue::String) = push!.(g.issues, issue)

function apply_video_metadata!(g, m::NamedTuple)
    g.dimension .= Ref((m.width, m.height))   # Ref, or the tuple broadcasts one element per row
    g.duration  .= m.duration
    g.video_fps .= m.fps
    g.sar       .= m.sar
    # impute the blank-able parameters from the video itself (a CSV-supplied value wins via coalesce)
    g.stop .= coalesce.(g.stop, m.duration)
    g.fps  .= coalesce.(g.fps,  m.fps)
    return
end

# window_size is either an Int side length or an (w, h) tuple; "non-positive" covers both shapes.
window_nonpositive(x) = x isa Tuple ? any(≤(0), x) : x ≤ 0

# Run-level fields, as opposed to the per-segment file/start/stop/start_location: the whole run
# shares one value (they end up in the run's `Source`), so segments of one run must agree on them —
# checked by verify_run_consistency! via `allequal`, which treats all-missing as agreeing. All but
# `calibration_id` and `dimension`/`sar` (ffprobe-read, not CSV columns) feed `track`.
const SHARED_PARAMS = (:target_width, :window_size, :darker_target, :fps,
    :initial_search_factor, :scale, :background_length, :calibration_id, :dimension, :sar)

# A run may be split across several CSV rows (one per segment video) sharing a :run_id. Those rows
# must agree on every run-level parameter; only file/start/stop/start_location may vary. Compared
# only among otherwise-clean rows, since a field nulled by an earlier failed check would read as a
# spurious disagreement.
function verify_run_consistency!(df::AbstractDataFrame)
    for g in groupby(df, :run_id)
        (nrow(g) > 1 && !ismissing(g.run_id[1]) && all(isempty, g.issues)) || continue
        conflicts = [c for c in SHARED_PARAMS if !allequal(g[!, c])]
        isempty(conflicts) && continue
        push!.(g.issues, "run segments disagree on " * join(conflicts, ", "))
    end
end

function verifications!(df::AbstractDataFrame, data_path)
    # :file becomes the canonical absolute path — the identity used for per-file reads and segment
    # grouping.
    resolve_paths!(df, data_path, :file)

    # One ffprobe per file: fills :dimension/:duration/:video_fps and imputes :stop/:fps.
    read_video_metadata!(df)

    # start_location is optional (missing rows skipped). It is (x, y) = (horizontal, vertical) in
    # *display* pixels, like a rectification's center/north, while ffprobe's width is in stored
    # pixels — so x is bounds-checked against the display width, width × sar, and y against height,
    # which sar does not affect.
    verify!(df, x -> any(<(1), x), "start_location cannot be smaller than 1", :start_location)
    verify!(df, (sl, dim, sar) -> sl[1] > dim[1] * sar || sl[2] > dim[2], "start_location is outside the frame", :start_location, :dimension, :sar)

    # Value ranges. Only what would make `track` error or misbehave nonsensically is flagged.
    verify!(df, ≤(0), "target_width must be larger than zero", :target_width)
    verify!(df, window_nonpositive, "window_size must be larger than zero", :window_size)
    verify!(df, ≤(0), "fps must be larger than zero", :fps)
    # track downsamples via round(video_fps/fps) - 1, so a requested fps above the video's own rate is nonsensical.
    verify!(df, (f, vf) -> f > vf, "fps cannot exceed the video frame rate", :fps, :video_fps)
    verify!(df, ≤(0), "initial_search_factor must be larger than zero", :initial_search_factor)
    verify!(df, ≤(0), "scale must be larger than zero", :scale)
    # scale is a downsampling factor; > 1 would artificially enlarge the frames for no benefit.
    verify!(df, >(1), "scale cannot be larger than one", :scale)
    # The tracker works in the scaled frame, so it is the *scaled* target width that must span at
    # least one pixel — each factor can be individually fine while their product is degenerate.
    # Below roughly half a pixel the tracker stops finding the target at all, and does NOT throw, so
    # without this check the result is a plausible-looking track of nothing (#24). The check uses
    # the *declared* target_width, so over-declaring it permits a scale too small for the real
    # target.
    verify!(df, (tw, sc) -> tw * sc < 1, "scaled target width (target_width × scale) is smaller than one pixel", :target_width, :scale)
    # 0 is a real mode (no background subtraction); 1–24 is a background model too short to model
    # anything, and negatives are nonsense — the predicate covers both.
    verify!(df, b -> b != 0 && b < 25, "background_length must be 0 (disables background subtraction) or at least 25", :background_length)

    # Temporal window must be sane and lie within the video. start ≥ 0 runs first and nulls :start
    # on failure, so a negative start does not also trip "start must come before stop".
    verify!(df, <(0), "start must be larger than or equal to zero", :start)
    verify!(df, (a, o) -> a ≥ o, "start must come before stop", :start, :stop)
    verify!(df, (o, d) -> o > d, "stop can not come after video duration", :stop, :duration)
    verify!(df, (a, d) -> a > d, "start can not come after video duration", :start, :duration)
    # PawsomeTracker reads round(Int, fps × (stop − start)) frames, so a window shorter than half a
    # frame period reads none at all, and a zero-frame segment crashes the multi-segment track.
    verify!(df, (o, a, f) -> round(Int, f * (o - a)) < 1, "temporal window is too short to contain a single frame at this fps", :stop, :start, :fps)

    # Cross-row: segments of one run (shared :run_id) must agree on the run-level parameters.
    verify_run_consistency!(df)

    return df
end
