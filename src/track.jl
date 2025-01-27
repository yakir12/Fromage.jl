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

    cols = (:file, :runs_start, :runs_stop)
    runs = combine(groupby(runs, :run_id), Not(cols...) .=> Ref ∘ first,  Cols(cols...) .=> Ref ∘ (x -> length(x) == 1 ? only(x) : x), renamecols = false)

    # useful for naming the diagnostic videos
    transform!(runs, :run_id => ByRow(i -> "$i.csv") => :tij_file)


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

function track_all(runs, results_dir, data_path)

    runs = massage!(runs, data_path)

    # # TODO: rm
    subset!(runs, :run_id => ByRow(==(69))) # took 0:01:23 without calibrations
    # subset!(runs, :row_number => ByRow(x -> 1 < x < 10)) # took 0:01:23 without calibrations

    p = Progress(nrow(runs); desc = "Tracking all the runs:")
    mktempdir(results_dir) do path
        Threads.@threads for row in eachrow(runs)
            if length(row.file) == 1
                files = joinpath(data_path, row.runs_path, only(row.file))
                kwargs = omit_missing(row, (:runs_start => :start, :runs_stop => :stop, :target_width => :target_width, :start_location => :start_location, :window_size => :window_size, :darker_target => :darker_target, :fps => :fps))
            else
                kwargs = omit_missing(row, (:runs_start => :start, :runs_stop => :stop, :target_width => :target_width, :start_location => :start_location, :window_size => :window_size, :darker_target => :darker_target, :fps => :fps))
                files = joinpath.(data_path, row.runs_path, row.file)
            end
            t, ij = track(files; kwargs..., diagnostic_file = joinpath(path, string(row.run_id, ".ts")))
            CSV.write(joinpath(results_dir, row.tij_file), DataFrame(t = t, i = first.(Tuple.(ij)), j = last.(Tuple.(ij))))
            next!(p)
        end
        file_list = join((joinpath(path, string(run_id, ".ts")) for run_id in runs.run_id), '|')
        out = joinpath(results_dir, "diagnostic.mp4")
        run(`ffmpeg -y -loglevel 8 -i "concat:$file_list" -c copy $out`)
    end
    finish!(p)

    CSV.write(joinpath(results_dir, "runs.csv"), rename(select(runs, Not(:csv_source)), :file => :runs_file))
    # @info "done!"
end

