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

# `rectification_defaults`/`tracking_defaults` globally replace the hardcoded defaults of the
# tuning parameters (e.g. `rectification_defaults = (n_corners = (5, 8), blur = 0)`,
# `tracking_defaults = (target_width = 60,)`). The hierarchy is: csv cell → these kwargs → the
# hardcoded/probed defaults. Each gateway whitelists what may be set (see DEFAULTS in the
# respective parsers.jl) and rejects anything else up front.
function main(data_path::String; calibs_file = "calibs.csv", runs_file = "runs.csv",
        rectification_defaults = (;), tracking_defaults = (;), run_ids = nothing)

    mkpath(results_dir)

    cs = load_rectifications(joinpath(data_path, calibs_file); defaults = rectification_defaults)
    rs = load_runs(joinpath(data_path, runs_file); defaults = tracking_defaults)

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

    return runs

end

function only_track(data_path::String; runs_file = "runs.csv", tracking_defaults = (;), run_ids = nothing)

    mkpath(results_dir)

    rs = load_runs(joinpath(data_path, runs_file); defaults = tracking_defaults)

    if !isnothing(run_ids)
        filter!(r -> r.run_id ∈ run_ids, rs)
    end

    runs = @showprogress desc = "Building runs" tmap((i, r) -> track(r; diagnostic_file = joinpath(results_dir, "$i.mp4")), 1:length(rs), rs)

    return runs
end

function only_rectify(data_path::String; calibs_file = "calibs.csv", rectification_defaults = (;), calibration_ids = nothing)
    mkpath(results_dir)

    cs = load_rectifications(joinpath(data_path, calibs_file); defaults = rectification_defaults)

    if !isnothing(calibration_ids)
        filter!(c -> c.calibration_id ∈ calibration_ids, cs)
    end

    calibs = @showprogress desc = "Building rectifications" tmap(Rectification, cs)

end
