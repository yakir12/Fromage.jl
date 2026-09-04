# Probe one video file with a single ffprobe call: frame width/height (stored pixels), sample aspect
# ratio, container duration and the (real) frame rate. Returns a NamedTuple, or an "issue reading..."
# string for a corrupt/unreadable file. The spawn, its `key=value` output and the per-field parsers
# are shared with VerifyRectifications in ..Probing; what stays here is which entries this gateway
# asks for and which of them it cannot proceed without. The frame rate is one of those — it imputes
# the run's `native_fps` when the csv leaves it blank, and through it the `sample_fps` as well. `sar`
# has a documented square-pixel fallback, so a missing one is not an error.
#
# `avg_frame_rate` and `field_order` are asked for on the same spawn (no extra probe) purely so
# `native_framerate` can recognise field-coded interlaced footage, whose `r_frame_rate` is the field
# rate rather than the frame rate — see #145 and the note there.
function probe_video(file)
    fields = probe_fields(file, "stream=width,height,r_frame_rate,avg_frame_rate,field_order,sample_aspect_ratio:format=duration")
    fields isa String && return fields                 # unreadable file: pass the issue straight on
    geometry = frame_geometry(fields)
    fps = native_framerate(fields)
    if isnothing(geometry) || isnothing(fps)
        return no_video_stream("width/height/duration/frame rate")
    end
    return (; geometry..., fps, sar = parse_sar(get(fields, "sample_aspect_ratio", "1:1")))
end

# One ffprobe per physical video file fills the intermediate :dimension/:duration/:sar columns and
# imputes the three blank-able run parameters: :stop (← duration), :native_fps (← the video's own
# frame rate) and :sample_fps (← :native_fps).
function read_video_metadata!(df::AbstractDataFrame; progress = true)
    blank!(df, :dimension, :duration, :sar, :probed_fps)
    read_per_file!(df, :file, [:file], "Reading runs videos...", probe_video, apply_video_metadata!; progress)
end

apply_video_metadata!(g, issue::String) = push!.(g.issues, issue)

function apply_video_metadata!(g, m::NamedTuple)
    g.dimension  .= Ref((m.width, m.height))  # Ref, or the tuple broadcasts one element per row
    g.duration   .= m.duration
    g.sar        .= m.sar
    # kept, though :native_fps may now say otherwise: it is what bounds a declared rate below (a
    # declaration cannot conjure frames the file does not hold), and nothing else reads it
    g.probed_fps .= m.fps
    # impute the blank-able parameters from the video itself (a CSV-supplied value wins via coalesce)
    g.stop .= coalesce.(g.stop, m.duration)
    # The rate cascade, in order: what the file reports is only a fallback for :native_fps (a
    # declared one has already been spread across the run by resolve_native_fps!), and :sample_fps
    # falls back to whichever of the two :native_fps ended up being — never to the probe directly.
    # That is what makes `native_fps = 25` on its own also track at 25.
    g.native_fps .= coalesce.(g.native_fps, m.fps)
    g.sample_fps .= coalesce.(g.sample_fps, g.native_fps)
    return
end

# A declared `native_fps` describes the RUN, not the one video whose row it was written on: the
# segments of a run are pieces of one recording and share their specs — segments that do not are
# outside what this program tracks (see runs.md) — so one row naming the rate names it for all of
# them. Spreading it here, before the probe imputes anything, is what makes that true: a blank row
# would otherwise fall back to its own file's probed rate and end up disagreeing with the row that
# named one.
#
# Two rows naming DIFFERENT rates is the one case that cannot be honoured, since both claims are
# about the same recording; it is reported rather than silently resolved in favour of a row.
function resolve_native_fps!(df::AbstractDataFrame)
    for g in groupby(df, :run_id)
        (!ismissing(g.run_id[1]) && all(isempty, g.issues)) || continue
        declared = unique(skipmissing(g.native_fps))
        isempty(declared) && continue
        if length(declared) > 1
            push!.(g.issues, "run segments disagree on native_fps")
        else
            g.native_fps .= only(declared)
        end
    end
    return df
end

# window_size is either an Int side length or an (w, h) tuple; "non-positive" covers both shapes.
# Two methods rather than a runtime `isa`: the field's own type is `Union{Int, NTuple{2,Int}}`, and
# a union of concrete types is exactly what dispatch is for.
window_nonpositive(x::Tuple) = any(≤(0), x)
window_nonpositive(x) = x ≤ 0

# Run-level fields, as opposed to the per-segment file/start/stop/start_location: the whole run
# shares one value (they end up in the run's `Tuning`), so segments of one run must agree on them —
# checked by verify_run_consistency! via `allequal`, which treats all-missing as agreeing. All but
# `dimension`/`sar` (ffprobe-read, not CSV columns) feed `track`.
#
# `calibration_id` is deliberately absent: it is an identity, so `verify_ids!` compares it in the
# first tier, before any video is opened (#121). Re-comparing it here would report the same
# disagreement twice.
#
# Both rates are here. A DECLARED `native_fps` cannot trip this — resolve_native_fps! has already
# made it uniform, or reported the contradiction — so what it catches is the imputed case: segments
# whose files genuinely report different rates. #95 left the probed rate out of this list to avoid
# rejecting one recording whose containers spell the same rate differently (`30000/1001` versus
# `2997/100`); that exposure is unchanged, because the rate has always reached this check anyway
# through the blank-cell imputation of what is now `sample_fps`. What has changed is that a run can
# now say what its rate is and be believed, which is the way out of such a rejection.
const SHARED_PARAMS = (:target_width, :window_size, :darker_target, :native_fps, :sample_fps,
    :initial_search_factor, :downscale, :background_length, :dimension, :sar)

# ---- first tier: identity ---------------------------------------------------------------------
# Everything here reads `run_id` and `calibration_id` and nothing else — no filesystem, no decoding.
# It runs before `verifications!` so that a mistyped or duplicated id fails before a single video is
# opened, instead of after the whole file has been probed and corner-detected (#121).
function verify_ids!(df::AbstractDataFrame)
    # run_id is all-or-nothing, and auto-numbered when every cell is blank. It comes first because
    # the grouping below, the issue report, and (in `main`) the cross-file check all need the final
    # value.
    resolve_run_ids!(df)
    # run_id names the track file and the diagnostic segments, so it must be a usable file name.
    verify_id_filename!(df, :run_id)
    verify_run_calibration!(df)
    return df
end

# A run must name exactly ONE calibration: everything downstream joins the two files on it. The
# other run-level parameters are compared by verify_run_consistency! in the second tier, where the
# ffprobe-filled ones it also covers are available. Compared only among otherwise-clean rows, as
# there: a row whose id cell was already flagged would read as a spurious disagreement.
function verify_run_calibration!(df::AbstractDataFrame)
    for g in groupby(df, :run_id)
        (nrow(g) > 1 && !ismissing(g.run_id[1]) && all(isempty, g.issues)) || continue
        allequal(g.calibration_id) && continue
        push!.(g.issues, "run segments disagree on calibration_id")
    end
    return df
end

# ---- second tier ------------------------------------------------------------------------------

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

# The second tier: everything that has to open a file, plus the value checks that depend on what
# those files report. `verify_ids!` has already run and passed (or, under `strict = false`, flagged
# the rows it rejected — which every stage below skips, since they all subset to unflagged rows).
function verifications!(df::AbstractDataFrame, data_path; progress = true)
    # :file becomes the canonical absolute path — the identity used for per-file reads and segment
    # grouping.
    resolve_paths!(df, data_path, :file)

    # A rate declared on any row of a run is a statement about the whole run, so it is spread
    # across its rows BEFORE the probe fills the blanks — otherwise the probe would win on the rows
    # that were left blank.
    resolve_native_fps!(df)

    # One ffprobe per file: fills :dimension/:duration/:sar and imputes :stop/:native_fps/:sample_fps.
    read_video_metadata!(df; progress)

    # start_location is optional (missing rows skipped). It is (x, y) = (horizontal, vertical) in
    # *display* pixels, like a rectification's center/north, while ffprobe's width is in stored
    # pixels — so x is bounds-checked against the display width, width × sar, and y against height,
    # which sar does not affect.
    verify!(df, x -> any(<(1), x), "start_location cannot be smaller than 1", :start_location)
    verify!(df, (sl, dim, sar) -> sl[1] > dim[1] * sar || sl[2] > dim[2], "start_location is outside the frame", :start_location, :dimension, :sar)

    # Value ranges. Only what would make `track` error or misbehave nonsensically is flagged.
    verify!(df, ≤(0), "target_width must be larger than zero", :target_width)
    verify!(df, window_nonpositive, "window_size must be larger than zero", :window_size)
    verify!(df, ≤(0), "native_fps must be larger than zero", :native_fps)
    verify!(df, ≤(0), "sample_fps must be larger than zero", :sample_fps)
    # Sampling advances whole frames, so the fastest rate obtainable is the video's own: asking for
    # more cannot produce more, it can only produce a run whose timestamps claim a rate that was
    # never delivered. Both sides may have come from the csv, and the check is the same either way.
    verify!(df, (s, n) -> s > n, "sample_fps cannot exceed native_fps", :sample_fps, :native_fps)
    verify!(df, ≤(0), "initial_search_factor must be larger than zero", :initial_search_factor)
    verify!(df, ≤(0), "downscale must be larger than zero", :downscale)
    # A downsampling factor; > 1 would artificially enlarge the frames for no benefit.
    verify!(df, >(1), "downscale cannot be larger than one", :downscale)
    # The tracker works in the scaled frame, so it is the *scaled* target width that must span at
    # least one pixel — each factor can be individually fine while their product is degenerate.
    # Below roughly half a pixel the tracker stops finding the target at all, and does NOT throw, so
    # without this check the result is a plausible-looking track of nothing (#24). The check uses
    # the *declared* target_width, so over-declaring it permits a downscale too small for the real
    # target.
    verify!(df, (tw, sc) -> tw * sc < 1, "scaled target width (target_width × downscale) is smaller than one pixel", :target_width, :downscale)
    # 0 is a real mode (no background subtraction); 1–24 is a background model too short to model
    # anything, and negatives are nonsense — the predicate covers both.
    verify!(df, b -> b != 0 && b < 25, "background_length must be 0 (disables background subtraction) or at least 25", :background_length)

    # Temporal window must be sane and lie within the video. start ≥ 0 runs first and nulls :start
    # on failure, so a negative start does not also trip "start must come before stop".
    verify!(df, <(0), "start must be larger than or equal to zero", :start)
    verify!(df, (a, o) -> a ≥ o, "start must come before stop", :start, :stop)
    verify!(df, (o, d) -> o > d, "stop can not come after video duration", :stop, :duration)
    verify!(df, (a, d) -> a > d, "start can not come after video duration", :start, :duration)
    # A declared `native_fps` reinterprets the RATE, not the clock: `start`/`stop` stay in the
    # file's own seconds. So a rate above the one the file reports claims that window holds more
    # frames than it does, and the sampler runs off the end of the video partway through the run —
    # the one way a declared rate could break this gateway's promise that `track` cannot error. A
    # file that overstates its rate is the case worth declaring; one that understates it cannot be
    # expressed this way, because the extra frames it would need are not there.
    verify!(df, (n, p) -> n > p, "native_fps cannot exceed the frame rate the video file reports", :native_fps, :probed_fps)
    # A window shorter than half a frame period is not what anyone asking for a window meant. It
    # does not crash: `Video` floors its sample count at one (`max(1, floor(Int, …))`), so such a
    # segment yields a single-sample track instead — silently, which is why this is checked here.
    # (This used to claim a zero-frame segment crashed the multi-segment track. That `max` has made
    # it impossible, and a wrong reason invites someone to delete the check once they find out.)
    verify!(df, (o, a, f) -> round(Int, f * (o - a)) < 1, "temporal window is too short to contain a single frame at this sample_fps", :stop, :start, :sample_fps)

    # Cross-row: segments of one run (shared :run_id) must agree on the run-level parameters.
    verify_run_consistency!(df)

    return df
end
