const results_dir = "results_dir"

# Every segment shares one resolution, codec and quality (see diagnose.jl), so a single ffmpeg
# concat-demuxer call stream-copies them into the final video. The demuxer rewrites timestamps
# monotonically by design — unlike the former pairwise "concat:"-protocol tree, which leaned on
# per-join discontinuity heuristics with every warning hidden at -loglevel 8.
function concatenate(path, files)
    list = joinpath(path, "list.txt")
    open(list, "w") do io
        foreach(f -> println(io, "file '", f, "'"), files)
    end
    out = joinpath(results_dir, "diagnostic.mp4")
    ffmpeg_exe(` -y -loglevel error -f concat -safe 0 -i $list -c copy $out`)
end

# Save one run's track to results_dir/<run_id>.csv: one row per detected coordinate, with the
# `time` stamp (seconds into the video) and the `x`/`y` real-world coordinates. `track` already
# returns real-world coordinates: it applied the run's rectification's `image2real` — for the video
# kinds a pixel→real map, for AprilTag a metric ground map carrying the same centre/north gauge — so
# the origin is at `center`, north-aligned when `north` was given, in `checker_size`/`scale` units.
# Axis orientation follows the image — x rightward, y downward — as
# `(y-direction, x-direction)`, so we unpack `y, x`. AprilTag tracking reports `missing` for a frame
# whose target couldn't be localized (e.g. a tag was momentarily lost); such a row keeps its `time`
# with empty `x`/`y`, so the time axis stays intact and the gaps are explicit.
function save2csv(run_id, (ts, coords))
    open(joinpath(results_dir, string(run_id, ".csv")), "w") do io
        println(io, "time,x,y")
        for (t, c) in zip(ts, coords)
            if ismissing(c)
                println(io, t, ",,")
            else
                y, x = c
                println(io, t, ',', x, ',', y)
            end
        end
    end
end

# `rectification_defaults`/`tracking_defaults` globally replace the hardcoded defaults of the
# tuning parameters (e.g. `rectification_defaults = (n_corners = (5, 8), blur = 0)`,
# `tracking_defaults = (target_width = 60,)`). The hierarchy is: csv cell → these kwargs → the
# hardcoded/probed defaults. Each gateway whitelists what may be set (see DEFAULTS in the
# respective parsers.jl) and rejects anything else up front. `run_ids` restricts processing to
# the named runs (only the rectifications those runs reference are built).
function main(data_path::String; calibs_file = "calibs.csv", runs_file = "runs.csv",
        rectification_defaults = (;), tracking_defaults = (;), run_ids = nothing)

    mkpath(results_dir)

    # The loaders return the annotated DataFrame instead only under `strict = false`; on the
    # default strict path they provably return the run/rectification vectors — assert it so the
    # union doesn't leak downstream (JET flags e.g. `length(::DataFrame)` otherwise).
    cs = load_rectifications(joinpath(data_path, calibs_file); defaults = rectification_defaults, issues_dir = joinpath(results_dir, "issues"))::Vector{RectificationMethod}
    rs = load_runs(joinpath(data_path, runs_file); defaults = tracking_defaults)::Vector{Run}

    if !isnothing(run_ids)
        filter!(r -> r.run_id ∈ run_ids, rs)
    end

    run_calib_ids = [r.calibration_id for r in rs]
    filter!(c -> c.calibration_id ∈ run_calib_ids, cs)

    if any(∉(getfield.(cs, :calibration_id)), run_calib_ids)
        error("there are calibration IDs in the runs.csv file that are not present in the calibs.csv file")
    end

    calibs = DataFrame(calibration_id = getfield.(cs, :calibration_id), c = cs)

    calibs.rectification .= @showprogress desc = "Building rectifications" tmap(Rectification, calibs.c)

    runs = DataFrame(calibration_id = [r.calibration_id for r in rs], run_id = [r.run_id for r in rs], r = rs)
    leftjoin!(runs, calibs, on = :calibration_id)

    mktempdir() do path
        transform!(runs, :run_id => (x -> joinpath.(path, string.(x, ".mp4"))) => :diagnostic_file)
        runs.run .= @showprogress desc = "Building runs" tmap((r, c, rectification, diagnostic_file) -> track(r; center = c.source.center, rectification, diagnostic_file), runs.r, runs.c, runs.rectification, runs.diagnostic_file)
        concatenate(path, runs.diagnostic_file)
        select!(runs, Not(:diagnostic_file))
    end

    tforeach(save2csv, runs.run_id, runs.run)

    return runs

end

function only_track(data_path::String; runs_file = "runs.csv", tracking_defaults = (;), run_ids = nothing)

    mkpath(results_dir)

    rs = load_runs(joinpath(data_path, runs_file); defaults = tracking_defaults)::Vector{Run}

    if !isnothing(run_ids)
        filter!(r -> r.run_id ∈ run_ids, rs)
    end

    runs = @showprogress desc = "Building runs" tmap((i, r) -> track(r; diagnostic_file = joinpath(results_dir, "$i.mp4")), 1:length(rs), rs)

    return runs
end

function only_rectify(data_path::String; calibs_file = "calibs.csv", rectification_defaults = (;), calibration_ids = nothing)
    mkpath(results_dir)

    cs = load_rectifications(joinpath(data_path, calibs_file); defaults = rectification_defaults, issues_dir = joinpath(results_dir, "issues"))::Vector{RectificationMethod}

    if !isnothing(calibration_ids)
        filter!(c -> c.calibration_id ∈ calibration_ids, cs)
    end

    calibs = @showprogress desc = "Building rectifications" tmap(Rectification, cs)

end
