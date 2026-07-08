function verify_unique_ids!(df::AbstractDataFrame)
    tf = nonunique(df, :calibration_id) .&& completecases(df, :calibration_id)
    df.calibration_id[tf] .= missing
    push!.(df.issues[tf], "calibration_id must not repeat")
end

# One ffprobe call per physical video file yields width, height, duration, sample (pixel) aspect ratio
# and field order (interlacing). These fill the intermediate :duration/:dimension columns, set the
# video :width/:height (always taken from the file — they are the frame size used to decode it) and
# impute :aspect/:yadif. Grouping on the canonical resolved :file reads one physical file once, not
# once per spelling. (Replaces the former pair of VideoIO opens — aspect, then duration+dimension —
# and folds in the new ffprobe columns.)
function read_video_metadata!(df::AbstractDataFrame)
    # :width/:height have no CSV column (they are not user-supplied); create them here so the probe
    # can fill them, alongside the intermediate :duration/:dimension columns.
    @transform! df :duration = missing :dimension = missing :width = missing :height = missing
    gs = @chain df begin
        dropmissing([:file, :type], view = true)
        groupby([:file, :type])
    end
    # Every type now carries a source video (:file), so every group is probed once: the read fills
    # :duration/:dimension/:width/:height for all, plus imputes :aspect (and :yadif for video).
    groups = collect(gs)
    metas = @showprogress desc = "Reading calibration videos..." tmap(g -> probe_video(g.file[1]), groups)
    for (g, meta) in zip(groups, metas)
        apply_video_metadata!(g, meta)
    end
end

apply_video_metadata!(g, issue::String) = @transform! g :duration = missing :dimension = missing :issues = push!.(:issues, issue)

function apply_video_metadata!(g, m::NamedTuple)
    @transform! g :dimension = (m.width, m.height) :duration = m.duration
    # width/height are the real frame size (used to decode the video); always taken from the probe.
    g.width  .= m.width
    g.height .= m.height
    # aspect is imputed only when the CSV left it blank — a user-supplied value wins.
    g.aspect .= coalesce.(g.aspect, m.aspect)
    g.type[1] == "video" || return                     # yadif (interlacing) is a video-only field
    g.yadif  .= coalesce.(g.yadif,  m.yadif)
    return
end

function findfirstkey(d, k)
    if d isa AbstractDict
        haskey(d, k) && return k => d[k]          # check current level first
        for v in values(d)
            r = findfirstkey(v, k)
            r === nothing || return r
        end
    elseif d isa AbstractVector || d isa Tuple
        for v in d
            r = findfirstkey(v, k)
            r === nothing || return r
        end
    end
    return nothing
end

# Pull the frame size out of an already-read .mat dict. ImageSize is an unconstrained Any, so validate
# shape/eltype here: a malformed value yields an issue string instead of an uncaught throw
# (InexactError/MethodError) or a silently-wrong dimension. matlab stores ImageSize as [height, width];
# we return (width, height).
function matlab_dimension(dict)
    res = findfirstkey(dict, "ImageSize")
    if isnothing(res)
        return "matlab file does not contain any image size; file might not be a calibration file"
    end
    imagesize = last(res)
    try
        length(imagesize) == 2 || return "matlab ImageSize is malformed (expected two values)"
        height, width = imagesize
        return (Int(width), Int(height))
    catch
        return "matlab ImageSize is malformed (expected two integers)"
    end
end

# The fields CameraCalibrations.jl needs to build a calibration object from a matlab result file.
const MATLAB_REQUIRED_KEYS = ("TranslationVectors", "RotationVectors", "RadialDistortion", "K")

# A genuine MAT-file (v5/v7) begins with the ASCII text "MATLAB" in its header. Reading just the
# first 6 bytes is a cheap, specific guard: a non-mat file gets this clear issue instead of matread's
# opaque error. `read(file, 6)` opens the file and returns up to 6 bytes (fewer if the file is
# shorter), so a too-short file simply fails the comparison.
function matlab_magic_issue(file)
    magic = try
        read(file, 6)
    catch e
        return "error reading matlab file: $e"
    end
    magic == codeunits("MATLAB") ? nothing : "file is not a matlab file (missing \"MATLAB\" magic bytes)"
end

# Read a .mat once: magic-check the header (cheap, specific) then matread. Returns the parsed dict, or
# an issue string for a non-mat / unreadable file. Every matlab metadatum derives from this one read.
function read_matlab(file)
    issue = matlab_magic_issue(file)
    isnothing(issue) || return issue
    try
        matread(file)
    catch e
        return "error opening matlab file: $e"
    end
end

# A matlab calibration file is only usable if it carries all of MATLAB_REQUIRED_KEYS (searched nested,
# like the ImageSize lookup). Returns an issue string naming the absent fields, otherwise `nothing`.
function matlab_missing_keys(dict)
    absent = filter(k -> isnothing(findfirstkey(dict, k)), collect(MATLAB_REQUIRED_KEYS))
    isempty(absent) && return nothing
    return "matlab file is missing required calibration field(s): " * join(absent, ", ")
end

# One matread per physical .mat file feeds everything: the structure check (a bad/unreadable/
# incomplete file gets :matlab_file nulled, dropping it from later passes), the extrinsic-pose count
# (:n_extrinsics) and the ImageSize cross-check against the source video. Grouping on the canonical
# resolved :matlab_file reads each physical file once. The source-video :dimension was already filled
# by read_video_metadata!, so the cross-check runs here against it.
function read_matlab_metadata!(df::AbstractDataFrame)
    @transform! df :n_extrinsics = missing
    gs = @chain df begin
        dropmissing([:matlab_file], view = true)   # matlab_file is set for matlab rows only
        groupby(:matlab_file)
    end
    mats = collect(gs)
    metas = @showprogress desc = "Reading matlab calibration files..." tmap(g -> matlab_metadata(g.matlab_file[1]), mats)
    for (g, meta) in zip(mats, metas)
        apply_matlab_metadata!(g, meta)
    end
end

# Pure read+derive: one matread, then structure/extrinsic-count/dimension off the same dict. A bad
# header, unreadable file or absent required key is a structure issue (the caller nulls :matlab_file);
# otherwise returns the extrinsic count (or its issue) and the .mat's ImageSize dimension (or its issue).
function matlab_metadata(file)
    dict = read_matlab(file)
    dict isa String && return dict
    keys_issue = matlab_missing_keys(dict)
    isnothing(keys_issue) || return keys_issue
    return (; n_extrinsics = matlab_extrinsic_count(dict), dimension = matlab_dimension(dict))
end

apply_matlab_metadata!(g, structure_issue::String) = @transform! g :matlab_file = missing :issues = push!.(:issues, structure_issue)

function apply_matlab_metadata!(g, m::NamedTuple)
    m.n_extrinsics isa String ? (@transform! g :extrinsic_index = missing :issues = push!.(:issues, m.n_extrinsics)) :
                                (@transform! g :n_extrinsics = m.n_extrinsics)
    if m.dimension isa String
        @transform! g :issues = push!.(:issues, m.dimension)
    else
        # Cross-check the .mat's ImageSize against each row's source-video frame size (:dimension, set
        # by read_video_metadata!). Skip rows whose video read failed — :dimension missing, already flagged.
        for r in eachrow(g)
            if !ismissing(r.dimension) && r.dimension != m.dimension
                push!(r.issues, "matlab ImageSize $(m.dimension) does not match the source video dimensions $(r.dimension)")
            end
        end
    end
end

# A matlab calibration file holds one extrinsic pose per calibration image: TranslationVectors and
# RotationVectors are both (N×3). extrinsic_index selects one of those N poses, so it is valid iff
# 1 ≤ extrinsic_index ≤ N. Returns N, or an issue string if the vectors are malformed. Only called
# after matlab_missing_keys confirmed both keys are present, so findfirstkey won't be nothing.
function matlab_extrinsic_count(dict)
    counts = Int[]
    for k in ("TranslationVectors", "RotationVectors")
        vecs = last(findfirstkey(dict, k))
        n = try
            size(vecs, 1)            # N×3 -> N poses
        catch
            return "matlab $k is malformed (expected an N×3 matrix)"
        end
        push!(counts, n)
    end
    allequal(counts) || return "matlab TranslationVectors and RotationVectors disagree on the number of extrinsics"
    return first(counts)
end

const INTERLACED_FIELD_ORDERS = ("tt", "bb", "tb", "bt")

# Reduce ffprobe's "num:den" sample aspect ratio to a Float64, mirroring VideoIO.aspect_ratio's
# fallback: an undefined / zero / nonsensical ratio defaults to 1.0.
function parse_sample_aspect(s)
    occursin(':', s) || return 1.0
    num, den = tryparse.(Int, split(s, ':'))
    (num === nothing || den === nothing || den == 0 || num == 0) ? 1.0 : num / den
end

# Probe one video file with a single ffprobe call: frame width/height, container duration, sample
# (pixel) aspect ratio and field order (interlacing). Returns a NamedTuple, or an "issue reading..."
# string if the file can't be probed (corrupt/unreadable). Uses the non-do-block `ffprobe()` (an
# env-baked Cmd; the deprecated do-block form mutates the global ENV, a race under the tmap that
# calls this); stderr is dropped so ffmpeg's diagnostics don't leak into the program output.
function probe_video(file)
    try
        exe = ffprobe()   # env-baked Cmd; its env survives interpolation into the command below
        out = read(pipeline(`$exe -v error -select_streams v:0 -show_entries stream=width,height,sample_aspect_ratio,field_order:format=duration -of default=noprint_wrappers=1 $file`, stderr = devnull), String)
        fields = Dict{String,String}()
        for line in eachline(IOBuffer(out))
            isempty(line) && continue
            k, v = split(line, '='; limit = 2)
            fields[k] = v
        end
        return (; width    = parse(Int, fields["width"]),
                  height   = parse(Int, fields["height"]),
                  duration = parse(Float64, fields["duration"]),
                  aspect   = parse_sample_aspect(get(fields, "sample_aspect_ratio", "1:1")),
                  yadif    = get(fields, "field_order", "progressive") in INTERLACED_FIELD_ORDERS)
    catch e
        return "issue reading from video file: $(sprint(showerror, e))"
    end
end

function verify!(df::AbstractDataFrame, predicate, msg, args...)
    field = first(args)
    cols = Cols(args...)
    @chain df begin
        subset(cols => ByRow(passmissing(predicate)), view = true, skipmissing = true)
        @transform! $field = missing :issues = push!.(:issues, msg)
    end
end

# function extract(extrinsic, file, to, blur)
#     if blur == 0
#         ffmpeg_exe(` -loglevel 8 -ss $extrinsic -i $file -vf yadif=1 -vframes 1 $to`)
#     else
#         ffmpeg_exe(` -loglevel 8 -ss $extrinsic -i $file -vf yadif=1,gblur=sigma=$blur -vframes 1 $to`)
#     end
# end

function extrinsic_issue(file, extrinsic, yadif, blur, width, height, n_corners)
    mktempdir() do path
        # to = CameraCalibrations.extract(extrinsic, file, path, blur)
        # @show to
        try
            vf = _vf(yadif, blur)
            res = get_corners(file, extrinsic, vf, width, height, n_corners)
            if ismissing(res)
                return "no corners detected"
            else
                return nothing
            end
        catch e
            return "issue with corner detection: $e"
        end
    end
end

function verify_extrinsics!(df::AbstractDataFrame)
    # :file is the canonical resolved path, so grouping on it corner-detects a file reached via different
    # spellings once per (extrinsic, blur, n_corners).
    gs = @chain df begin
        subset(:type => ByRow(passmissing(==("video"))), view = true, skipmissing = true)
        dropmissing([:file, :extrinsic, :blur, :n_corners], view = true)
        @groupby [:file, :extrinsic, :yadif, :blur, :width, :height, :n_corners]
    end
    issues = @showprogress desc = "Validating extrinsics..." tmap(k -> extrinsic_issue(k.file, k.extrinsic, k.yadif, k.blur, k.width, k.height, k.n_corners), keys(gs))
    for (g, issue) in zip(gs, issues)
        if !isnothing(issue)
            @transform! g :extrinsic = missing :issues = push!.(:issues, issue)
        end
    end
end

# The camera-model fit needs at least 3 frames with detectable corners sampled from the
# [start, stop] window (the "temporal_step too short" check above only guarantees 3
# *sampled* frames, not 3 *detectable* ones). Detection stops as soon as 3 frames succeed, so a
# good window costs ~3 frame reads and only a genuinely bad one scans through to its end. Frames
# are read in small parallel batches; the global read semaphore in Rectifications bounds the
# concurrent opens exactly as in the real rectification.
function intrinsic_issue(file, start, stop, temporal_step, yadif, blur, width, height, n_corners)
    vf = _vf(yadif, blur)
    found = 0
    try
        for batch in Iterators.partition(start:temporal_step:stop, 4)
            corners = tmap(t -> get_corners(file, t, vf, width, height, n_corners), collect(batch))
            found += count(!ismissing, corners)
            found ≥ 3 && return nothing
        end
        return "fewer than 3 frames with detectable corners in the calibs window"
    catch e
        return "issue with corner detection in the calibs window: $e"
    end
end

function verify_intrinsics!(df::AbstractDataFrame)
    # Rows already flagged are skipped: a failed probe, extrinsic or window check implies this
    # (expensive) scan would fail too — re-running it wastes frame reads and re-reports noise.
    # A missing calibs window (both bounds blank) is skipped like everywhere else.
    gs = @chain df begin
        subset(:type => ByRow(passmissing(==("video"))), view = true, skipmissing = true)
        subset(:issues => ByRow(isempty), view = true)
        dropmissing([:file, :start, :stop, :temporal_step, :width, :height, :n_corners], view = true)
        @groupby [:file, :start, :stop, :temporal_step, :yadif, :blur, :width, :height, :n_corners]
    end
    issues = @showprogress desc = "Validating intrinsics..." tmap(k -> intrinsic_issue(k.file, k.start, k.stop, k.temporal_step, k.yadif, k.blur, k.width, k.height, k.n_corners), keys(gs))
    for (g, issue) in zip(gs, issues)
        if !isnothing(issue)
            @transform! g :start = missing :stop = missing :issues = push!.(:issues, issue)
        end
    end
end

function verify_unique_calibrations!(df::AbstractDataFrame)
    # What makes two rectifications "the same" is type-dependent, so partition by :type:
    #   * matlab / only_scale: identical on *every* field (calibration_id and issues aside).
    #   * video: identical on the identity key below. The remaining parameters are NOT part of identity
    #     (one video can carry several rectifications differing only in, say, blur), but two same-identity
    #     rows still *should* agree on them — when they don't, the duplicate also gets a
    #     conflicting-parameters issue.
    # :file is already the canonical resolved path, so equivalent spellings / path splits compare equal
    # with no per-call realpath. The throwaway :_row column carries each row's index in `df` so flags
    # written through the type-partitioned views land on the right rows.
    cmp = select(df, Not(:calibration_id, :issues))
    cmp._row = collect(axes(cmp, 1))
    # Compare only rows that are otherwise valid. A row that already failed an earlier check has had its
    # offending field(s) nulled to `missing`, which can make two genuinely-distinct rows collapse into a
    # spurious "duplicate" — and such rows are already reported, so there's nothing to gain by comparing them.
    ok = isempty.(df.issues)
    isvideo = ok .& coalesce.(cmp.type .== "video", false)

    # matlab / only_scale: nonunique keeps the first occurrence, flags the rest.
    nonvideo = @view cmp[ok .& .!coalesce.(cmp.type .== "video", false), :]
    nv_dups = nonvideo._row[nonunique(nonvideo, Not(:_row))]
    df[nv_dups, :calibration_id] .= missing
    push!.(df[nv_dups, :issues], "duplicate rectification")

    # video: group by identity; within each group keep the first occurrence and reject the rest.
    identity = [:file, :start, :stop, :extrinsic, :center, :north]
    other = [:checker_size, :n_corners, :temporal_step, :radial_parameters, :blur, :yadif, :aspect]
    for g in groupby(@view(cmp[isvideo, :]), identity)
        nrow(g) > 1 || continue
        g_dups = g._row[2:end]
        df[g_dups, :calibration_id] .= missing
        push!.(df[g_dups, :issues], "duplicate rectification")
        if any(c -> !allequal(g[!, c]), other)
            push!.(df[g_dups, :issues], "same rectification with conflicting parameters")
        end
    end
end

function verifications!(df::AbstractDataFrame, data_path)

    verify_unique_ids!(df)
    @transform! df :path = passmissing(joinpath).(data_path, :path)

    verify!(df, !isdir, "path does not exist", :path)

    verify!(df, (f, p) -> !isfile(joinpath(p, f)), "file does not exist", :file, :path)

    # matlab_file (the .mat, matlab rows only) is resolved against path just like :file. verify!
    # skips missing, so non-matlab rows (matlab_file === missing) are untouched.
    verify!(df, (f, p) -> !isfile(joinpath(p, f)), "matlab_file does not exist", :matlab_file, :path)

    # Collapse data_path/path/file into one canonical absolute path stored in :file (and do the
    # same for :matlab_file), then drop path — it has done its job (the isdir/isfile checks
    # above) and the resolved paths now subsume it. The single resolved :file is the identity used by
    # every later step (the read passes, duplicate detection) and :matlab_file groups the .mat reads.
    # realpath is safe because non-existent paths were nulled just above; passmissing leaves those
    # missing. (realpath, not bare joinpath, so "./x", "a/../x" and symlinks collapse to one key.)
    @transform! df :file = passmissing(joinpath).(:path, :file)
    @transform! df :file = passmissing(realpath).(:file)
    @transform! df :matlab_file = passmissing(joinpath).(:path, :matlab_file)
    @transform! df :matlab_file = passmissing(realpath).(:matlab_file)
    select!(df, Not(:path))

    # One read per physical file: ffprobe on the source video (every type) and matread on the .mat
    # (matlab). These fill the intermediate :duration/:dimension/:n_extrinsics columns, set the video
    # :width/:height from the probe and impute :aspect (and :yadif for video). read_video_metadata!
    # creates :duration/:dimension/:width/:height and sets the video frame size used to bounds-check
    # center/north and to cross-check the matlab ImageSize, so it runs before read_matlab_metadata!.
    read_video_metadata!(df)

    read_matlab_metadata!(df)

    # center/north are optional and left missing when omitted (no imputation). verify! skips missing
    # rows, so a missing center or north is simply not bounds-checked.
    for point in (:center, :north)
        verify!(df, x -> any(<(1), x), "$point cannot be smaller than 1", point)
        verify!(df, (poi, dim) -> any(poi .> dim), "$point cannot be larger than the dimensions of the frame", point, :dimension)
    end
    # if north wasn't missing, but center was wrong and set to missing here, then now we have a missing center but existing north. the following fixes that:
    @rtransform! df :north = ismissing(:center) ? missing : :north

    verify!(df, ≤(0), "aspect must be larger than zero", :aspect)
    verify!(df, ≤(0), "scale must be larger than zero", :scale)
    verify!(df, ≤(0), "extrinsic_index must be larger than zero", :extrinsic_index)
    verify!(df, (i, n) -> i > n, "extrinsic_index exceeds the number of extrinsics in the matlab file", :extrinsic_index, :n_extrinsics)
    verify!(df, ≤(0), "checker_size must be larger than zero", :checker_size)
    verify!(df, ∉(1:3), "radial_parameters must be 1, 2, or 3", :radial_parameters)
    verify!(df, <(0), "blur must be larger than or equal to zero", :blur)
    # a checkerboard needs at least a 2×2 grid of inner corners: OpenCV's detector can't find a
    # 1-wide pattern, and checker_size_pixel divides by 2·prod(n) − sum(n), which is 0 at (1, 1)
    verify!(df, x -> any(<(2), x), "n_corners must all be at least 2", :n_corners)
    verify!(df, <(0), "extrinsic must be larger than or equal to zero", :extrinsic)
    # strictly before: seeking at exactly the duration yields no frame at all
    verify!(df, (e, d) -> e ≥ d, "extrinsic must come before the video duration", :extrinsic, :duration)
    # The intrinsic-calibration window must be sane and lie within the video. These run before the
    # temporal_step checks and null start/stop on failure, so a bad window does not also
    # trip the misleading "temporal_step too short" message (which is skipped once either bound is missing).
    verify!(df, <(0), "start must be larger than or equal to zero", :start)
    verify!(df, (a, o) -> a ≥ o, "start must come before stop", :start, :stop)
    verify!(df, (o, d) -> o > d, "stop can not come after video duration", :stop, :duration)

    verify!(df, ≤(0), "temporal_step must be larger than zero", :temporal_step)
    verify!(df, (t, a, o) -> (o - a) ÷ t + 1 < 3, "temporal_step too short (results in less than 3 intrinsic images)", :temporal_step, :start, :stop)

    # verify that the extrinsic time stamp works (should only be done after extrinsic time-stamps have been verified
    verify_extrinsics!(df)

    # the calibs window must actually contain ≥ 3 detectable-corner frames; runs after
    # verify_extrinsics! so rows whose extrinsic already failed are skipped, not re-scanned
    verify_intrinsics!(df)

    verify_unique_calibrations!(df)

end
