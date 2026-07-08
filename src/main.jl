const results_dir = "results_dir"

function concatenate(path, files)
    filess = [files]
    todo = Iterators.partition(filess[end], 2)
    args = [join.(todo, "|")]
    iter = 1
    outs = [[joinpath(path, "$iter-$i.ts") for i in 1:length(todo)]]
    while length(last(args)) > 1
        todo = Iterators.partition(outs[end], 2)
        push!(args, join.(todo, "|"))
        iter += 1
        out = [joinpath(path, "$iter-$i.ts") for i in 1:length(todo)]
        push!(outs, out)
    end
    for (arg, out) in zip(args, outs)
        Threads.@threads for i in 1:length(arg)
            ffmpeg_exe(` -loglevel 8 -i "concat:$(arg[i])" -c copy $(out[i])`)
        end
    end
    arg = only(outs[end])
    out = joinpath(results_dir, "diagnostic.mp4")
    ffmpeg_exe(` -y -loglevel 8 -i $arg -c copy $out`)
end

function main(data_path::String; calibs_file = "calibs.csv", runs_file = "runs.csv", rows = nothing, todo = nothing, kwargs...)

    mkpath(results_dir)

    cs = load_calibrations(joinpath(data_path, calibs_file))
    rs = load_runs(joinpath(data_path, runs_file))

    run_calib_ids = [r.source.calibration_id for r in rs]
    filter!(c -> c.calibration_id ∈ run_calib_ids, cs)

    if any(∉(getfield.(cs, :calibration_id)), run_calib_ids)
        error("there are calibration IDs in the runs.csv file that are not present in the calibs.csv file")
    end

    calibs = DataFrame(calibration_id = getfield.(cs, :calibration_id), c = cs)

    calibs.calibration .= @showprogress desc = "Building rectifications" tmap(Rectification, calibs.c)

    runs = DataFrame(calibration_id = [r.source.calibration_id for r in rs], run_id = [r.source.run_id for r in rs], r = rs)
    leftjoin!(runs, calibs, on = :calibration_id)

    mktempdir() do path
        transform!(runs, :run_id => (x -> joinpath.(path, string.(x, ".ts"))) => :diagnostic_file)
        runs.run .= @showprogress desc = "Building runs" tmap((r, c, calibration, diagnostic_file) -> track(r; center = c.source.center, calibration, diagnostic_file), runs.r, runs.c, runs.calibration, runs.diagnostic_file)
        concatenate(path, runs.diagnostic_file)
        select!(runs, Not(:diagnostic_file))
    end

    return runs

end

function only_track(data_path::String; runs_file = "runs.csv", rows = nothing, kwargs...)

    mkpath(results_dir)

    rs = load_runs(joinpath(data_path, runs_file))

    if !isnothing(rows)
        rows = filter(≤(length(rs)), rows)
        rs = rs[rows]
    end

    runs = @showprogress desc = "Building runs" tmap((i, r) -> track(r; diagnostic_file = joinpath(results_dir, "$i.mp4")), 1:length(rs), rs)

    return runs
end

function only_calibrate(data_path::String; calibs_file = "calibs.csv", todo = nothing, kwargs...)
    mkpath(results_dir)

    cs = load_calibrations(joinpath(data_path, calibs_file))

    if !isnothing(todo)
        filter!(c -> c.calibration_id ∈ todo, cs)
    end

    calibs = @showprogress desc = "Building rectifications" tmap(Rectification, cs)

end
