# Reduce ffprobe's "num/den" r_frame_rate to a Float64. A zero denominator (undefined rate) falls
# back to the numerator so the value stays finite and the fps checks below behave sanely.
function parse_framerate(s)
    occursin('/', s) || return parse(Float64, s)
    num, den = split(s, '/')
    d = parse(Float64, den)
    iszero(d) ? parse(Float64, num) : parse(Float64, num) / d
end

# ffprobe reports the sample (pixel) aspect ratio as "num:den"; "N/A" or "0:1" mean undefined and
# fall back to square pixels. The display-space width of a frame is width × sar.
function parse_sar(s)
    parts = split(s, ':')
    length(parts) == 2 || return 1//1
    num = tryparse(Int, parts[1])
    den = tryparse(Int, parts[2])
    (isnothing(num) || isnothing(den) || num ≤ 0 || den ≤ 0) && return 1//1
    return num // den
end

# Probe one video file with a single ffprobe call: frame width/height (stored pixels), sample aspect
# ratio, container duration and the (real) frame rate. Returns a NamedTuple, or an "issue reading..."
# string for a corrupt/unreadable file. Uses the non-do-block `ffprobe()` (an env-baked Cmd; never
# mutates the global ENV); stderr is dropped so ffmpeg's diagnostics don't leak into the output.
function probe_video(file)
    try
        exe = ffprobe()   # env-baked Cmd; its env survives interpolation into the command below
        out = read(pipeline(`$exe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate,sample_aspect_ratio:format=duration -of default=noprint_wrappers=1 $file`, stderr = devnull), String)
        fields = Dict{String, String}()
        for line in eachline(IOBuffer(out))
            isempty(line) && continue
            k, v = split(line, '='; limit = 2)
            fields[k] = v
        end
        return (; width    = parse(Int, fields["width"]),
                  height   = parse(Int, fields["height"]),
                  duration = parse(Float64, fields["duration"]),
                  fps      = parse_framerate(fields["r_frame_rate"]),
                  sar      = parse_sar(get(fields, "sample_aspect_ratio", "1:1")))
    catch e
        return "issue reading from video file: $(sprint(showerror, e))"
    end
end

# One ffprobe per physical video file fills the intermediate :dimension/:duration/:video_fps columns
# and imputes the two blank-able run parameters: :stop (← duration) and :fps (← video frame rate).
# Grouping on the canonical resolved :file reads one physical file once, not once per spelling.
function read_video_metadata!(df::AbstractDataFrame)
    @transform! df :dimension = missing :duration = missing :video_fps = missing :sar = missing
    gs = @chain df begin
        dropmissing([:file], view = true)
        groupby(:file)
    end
    groups = collect(gs)
    metas = @showprogress desc = "Reading runs videos..." tmap(g -> probe_video(g.file[1]), groups)
    for (g, meta) in zip(groups, metas)
        apply_video_metadata!(g, meta)
    end
end

apply_video_metadata!(g, issue::String) = @transform! g :issues = push!.(:issues, issue)

function apply_video_metadata!(g, m::NamedTuple)
    @transform! g :dimension = (m.width, m.height) :duration = m.duration :video_fps = m.fps :sar = m.sar
    # impute the blank-able parameters from the video itself (a CSV-supplied value wins via coalesce)
    g.stop .= coalesce.(g.stop, m.duration)
    g.fps  .= coalesce.(g.fps,  m.fps)
    return
end

# window_size is either an Int side length or an (w, h) tuple; "non-positive" covers both shapes.
window_nonpositive(x) = x isa Tuple ? any(≤(0), x) : x ≤ 0

# Subset the rows whose `args` trip `predicate`, null the offending field (first of `args`) so later
# checks skip them, and record `msg`. `passmissing`/`skipmissing` leave already-missing fields alone.
function verify!(df::AbstractDataFrame, predicate, msg, args...)
    field = first(args)
    cols = Cols(args...)
    @chain df begin
        subset(cols => ByRow(passmissing(predicate)), view = true, skipmissing = true)
        @transform! $field = missing :issues = push!.(:issues, msg)
    end
end

# Run-level fields, as opposed to the per-segment file/start/stop/start_location: the whole run shares
# one value (they end up in the run's `Source`), so segments of one run must agree on them (checked by
# verify_run_consistency! via `allequal`, which treats all-missing as agreeing — isequal(missing,
# missing) is true). All but `calibration_id` (run metadata) and `dimension`/`sar` (the ffprobe-read
# pixel width/height and sample aspect ratio, not CSV columns) feed `track`.
const SHARED_PARAMS = (:target_width, :window_size, :darker_target, :fps,
    :initial_search_factor, :white_point, :scale, :calibration_id, :dimension, :sar)

# A run may be split across several CSV rows (one per segment video) sharing a :run_id. Those rows
# must agree on every run-level parameter — only file/start/stop/start_location may vary. Compared
# only among otherwise-clean rows: a field nulled by an earlier failed check would read as a spurious
# disagreement, and that row is already reported.
function verify_run_consistency!(df::AbstractDataFrame)
    for g in groupby(df, :run_id)
        (nrow(g) > 1 && !ismissing(g.run_id[1]) && all(isempty, g.issues)) || continue
        conflicts = [c for c in SHARED_PARAMS if !allequal(g[!, c])]
        isempty(conflicts) && continue
        push!.(g.issues, "run segments disagree on " * join(conflicts, ", "))
    end
end

function verifications!(df::AbstractDataFrame, data_path)
    # Resolve path against data_path, check existence, then collapse path/file into one
    # canonical absolute :file (the identity used for per-file reads and segment grouping) and drop
    # path. realpath is safe because non-existent paths were nulled to missing just above.
    @transform! df :path = passmissing(joinpath).(data_path, :path)
    verify!(df, !isdir, "path does not exist", :path)
    verify!(df, (f, p) -> !isfile(joinpath(p, f)), "file does not exist", :file, :path)
    @transform! df :file = passmissing(joinpath).(:path, :file)
    @transform! df :file = passmissing(realpath).(:file)
    select!(df, Not(:path))

    # One ffprobe per file: fills :dimension/:duration/:video_fps and imputes :stop/:fps.
    read_video_metadata!(df)

    # start_location is optional (missing rows skipped). It is (x, y) = (horizontal, vertical) in
    # *display* pixels — like a rectification's center/north — while ffprobe's width is in stored
    # pixels, so x is bounds-checked against the display width, width × sar (they only differ for
    # anamorphic videos); y against height, which sar does not affect.
    verify!(df, x -> any(<(1), x), "start_location cannot be smaller than 1", :start_location)
    verify!(df, (sl, dim, sar) -> sl[1] > dim[1] * sar || sl[2] > dim[2], "start_location is outside the frame", :start_location, :dimension, :sar)

    # Value ranges. Only what would make `track` error or misbehave nonsensically is flagged.
    verify!(df, ≤(0), "target_width must be larger than zero", :target_width)
    verify!(df, window_nonpositive, "window_size must be larger than zero", :window_size)
    verify!(df, ≤(0), "fps must be larger than zero", :fps)
    # track downsamples via round(video_fps/fps) - 1, so a requested fps above the video's own rate is nonsensical.
    verify!(df, (f, vf) -> f > vf, "fps cannot exceed the video frame rate", :fps, :video_fps)
    verify!(df, ≤(0), "initial_search_factor must be larger than zero", :initial_search_factor)
    verify!(df, ≤(0), "white_point must be larger than zero", :white_point)
    verify!(df, ≤(0), "scale must be larger than zero", :scale)
    # scale is a downsampling factor; > 1 would artificially enlarge the frames for no benefit.
    verify!(df, >(1), "scale cannot be larger than one", :scale)
    # the tracker works in the scaled frame, so it is the *scaled* target width that must span at
    # least one pixel — each factor can be individually fine while their product is degenerate.
    verify!(df, (tw, sc) -> tw * sc < 1, "scaled target width (target_width × scale) is smaller than one pixel", :target_width, :scale)

    # Temporal window must be sane and lie within the video. start ≥ 0 runs first and nulls :start on
    # failure, so a negative start does not also trip the "start must come before stop" message.
    verify!(df, <(0), "start must be larger than or equal to zero", :start)
    verify!(df, (a, o) -> a ≥ o, "start must come before stop", :start, :stop)
    verify!(df, (o, d) -> o > d, "stop can not come after video duration", :stop, :duration)
    verify!(df, (a, d) -> a > d, "start can not come after video duration", :start, :duration)
    # PawsomeTracker reads round(Int, fps × (stop − start)) frames, so a window shorter than half a
    # frame period reads none at all (and a zero-frame segment crashes the multi-segment track).
    verify!(df, (o, a, f) -> round(Int, f * (o - a)) < 1, "temporal window is too short to contain a single frame at this fps", :stop, :start, :fps)

    # Cross-row: segments of one run (shared :run_id) must agree on the run-level parameters.
    verify_run_consistency!(df)

    return df
end
