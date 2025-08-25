function get_runs_df(data_path)
    files = get_all_csv(data_path, "run")
    tbl = CSV.File(files; source = :csv_source, stripwhitespace = true)
    df = DataFrame(tbl)
    fix_issue_1146!(df, files)
    return df
end

function massage!(runs, data_path)

    # start_datetime
    transform!(runs, [:runs_recording_datetime, :runs_start] => ByRow(Missings.passmissing((dt, s) -> dt + Second(round(Int, s)))) => :start_datetime)

    cols = (:file, :runs_start, :runs_stop, :start_location)
    runs = combine(groupby(runs, :run_id), Not(cols..., :POI) .=> Ref ∘ first, [:POI, :runs_stop] => Ref ∘ ((poi, stop) -> length(poi) == 1 ? only(poi) : coalesce(poi..., stop[1])) => :poi, Cols(cols...) .=> Ref ∘ (x -> length(x) == 1 ? only(x) : x), renamecols = false)

    # useful for naming the diagnostic videos
    transform!(runs, :run_id => ByRow(i -> "$i.csv") => :tij_file)

    rename!(runs, :runs_start => :start, :runs_stop => :stop)

    # now I don't need this
    # # prepare the df for the start_location is an Int
    # # TODO: maybe you can pack this into one transform, would be nicer in terms of typing
    # runs.row_uuid .= [uuid4() for _ in 1:nrow(runs)]
    # runs.start_location = convert(Vector{Union{Missing, Tuple{Int, Int}, Int, UUID}}, runs.start_location)
    # for g in groupby(runs, :csv_source), row in eachrow(g)
    #     if row.start_location isa Int
    #         row.start_location = g.row_uuid[row.start_location]
    #     end
    # end


    # # this needs to move to analysis
    # transform!(runs, [:start_datetime, :station] => ByRow(get_sun_elevation_azimuth) => [:elevation, :azimuth])

    return runs
end

function concatenate(path, files, results_dir)
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
            # run(`ffmpeg -i "concat:$(arg[i])" -c copy $(out[i])`)
            ffmpeg_exe(` -loglevel 8 -i "concat:$(arg[i])" -c copy $(out[i])`)
        end
    end
    arg = only(outs[end])
    out = joinpath(results_dir, "diagnostic.mp4")
    # run(`ffmpeg -i $arg -c copy $out`)
    ffmpeg_exe(` -loglevel 8 -i $arg -c copy $out`)
end

function track_all(runs, results_dir, data_path)

    runs = massage!(runs, data_path)

    # # TODO: rm
    # subset!(runs, :start_datetime => ByRow(>(Date(2025))))
    # subset!(runs, :run_id => ByRow(∈((15, ))))



    mktempdir(results_dir) do path
        p = Progress(nrow(runs); desc = "Tracking all the runs:")
        Threads.@threads for row in eachrow(runs)
        # for row in eachrow(runs)
            # kwargs = omit_missing(row, (:runs_start => :start, :runs_stop => :stop, :target_width => :target_width, :start_location => :start_location, :window_size => :window_size, :darker_target => :darker_target, :fps => :fps))
            kwargs = (k => v for (k, v) in pairs(skipmissing(row)) if k ∈ (:start, :stop, :target_width, :start_location, :window_size, :darker_target, :fps))
            files = if length(row.file) == 1
                joinpath(data_path, row.runs_path, only(row.file))
            else
                joinpath.(data_path, row.runs_path, row.file)
            end

            # @show files
            # @show (; kwargs...)

            t, ij = track(files; kwargs..., diagnostic_file = joinpath(path, string(row.run_id, ".ts")))
            CSV.write(joinpath(results_dir, row.tij_file), DataFrame(t = t, i = first.(Tuple.(ij)), j = last.(Tuple.(ij))))
            next!(p)
        end
        finish!(p)
        file_list = [joinpath(path, string(run_id, ".ts")) for run_id in runs.run_id]
        concatenate(path, file_list, results_dir)
    end

    CSV.write(joinpath(results_dir, "runs.csv"), rename(select(runs, Not(:csv_source)), :file => :runs_file))
    # @info "done!"
end


# function prepare_files(x)
#     if length(x) == 1
#         only(x)
#     else
#         Ref(x)
#     end
# end
#
# function prepare_kwargs(grp)
#     if nrow(grp) == 1
#         return (k => v for (k, v) in pairs(grp[1,:]) if !ismissing(v))
#     else
#         (k => grp[!, k] for k in (:start, :stop, :start_location) if hasproperty(grp, k)
#             grp.start
#         kwargs = (k => v for (k, v) in pairs(skipmissing(row)) if k ∈ (:start, :stop, :target_width, :start_location, :window_size, :darker_target, :fps))
#     end
#     return run_id, files, kwargs
# end
#
# function prepare_row(t, coord::CartesianIndex{2})
#     i, j = Tuple(coord)
#     (; t, i, j)
# end
#
# function track(results_dir, runs_file; diagnose = false)
#     df = CSV.read(runs_file, DataFrame)
#     df = combine(groupby(df, :run_id), :file => prepare_files => :files, Not(:file, :run_id) => prepare_kwargs => :kwargs)
#     mktempdir() do path
# #                                                                                   *      *      *                   *
#         @showprogress desc = "Tracking all the runs:" Threads.@threads for (run_id, files, start, stop, target_width, start_location, window_size, darker_target, fps) in tbl
#             diagnostic_file = diagnose ? joinpath(path, string(run_id, ".ts")) : nothing
#             ts, coords = track(files; start, stop, target_width, start_location, window_size, darker_target, fps, diagnostic_file)
#             CSV.write(joinpath(results_dir, "$run_id.csv"), prepare_row.(ts, coords))
#         end
#         if diagnose
#             file_list = join(readdir(path; join = true), '|')
#             out = joinpath(results_dir, "diagnostic.mp4")
#             run(`ffmpeg -y -loglevel 8 -i "concat:$file_list" -c copy $out`)
#         end
#     end
# end
