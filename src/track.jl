function get_runs_df(data_path)
    files = get_all_csv(data_path, "run")
    tbl = CSV.File(files; source = :csv_source, stripwhitespace = true)
    df = DataFrame(tbl)
    fix_issue_1146!(df, files)
    return df
end

function massage!(runs, data_path)

    # make sure run_id is globally unique and correct
    transform!(groupby(runs, [:csv_source, :run_id]), groupindices => :temp_run_id)
    rename!(select!(runs, Not(:run_id)), :temp_run_id => :run_id)

    # prepare the df for the start_location is an Int
    # TODO: maybe you can pack this into one transform, would be nicer in terms of typing
    runs.row_uuid .= [uuid4() for _ in 1:nrow(runs)]
    runs.start_location = convert(Vector{Union{Missing, Tuple{Int, Int}, Int, UUID}}, runs.start_location)
    for g in groupby(runs, :csv_source), row in eachrow(g)
        if row.start_location isa Int
            row.start_location = g.row_uuid[row.start_location]
        end
    end

    # start_datetime
    transform!(runs, [:runs_recording_datetime, :runs_start] => ByRow(Missings.passmissing((dt, s) -> dt + Second(round(Int, s)))) => :start_datetime)

    # # this needs to move to analysis
    # transform!(runs, [:start_datetime, :station] => ByRow(get_sun_elevation_azimuth) => [:elevation, :azimuth])

end

function track_all(runs, results_dir, data_path)

    massage!(runs, data_path)

    # # TODO: rm
    subset!(runs, :row_number => ByRow(x -> 177 < x < 197)) # took 0:01:23 without calibrations


    dofirst = innerjoin(runs, select(runs, :start_location), on = :row_uuid => :start_location, matchmissing=:notequal)
    dosecond = antijoin(runs, select(runs, :start_location), on = :row_uuid => :start_location, matchmissing=:notequal)

    # TODO: you should probably have an API for these split runs. A split could be due to a hand coming in, but could also be due to split files. run_id is your friend. 
    # tforeach doesn't work. dunno why. see if you can dumb down the process, which should be helped by the previouis point. 
    # have an API for these split files. and run each iteration per each run (not row).
    #
    p = Progress(nrow(runs); desc = "Tracking all the runs:")
    mktempdir(results_dir) do path
        # @info "started dofirst"
        start_locations = tmap(eachrow(dofirst)) do row
            # for row in eachrow(dofirst)
            # @info "doing row $(row.row_number)"
            # row_number, row = first(enumerate(eachrow(dofirst)))
            file = joinpath(data_path, row.runs_path, row.file)
            kwargs = omit_missing(row, (:runs_start => :start, :runs_stop => :stop, :target_width => :target_width, :start_location => :start_location, :window_size => :window_size, :darker_target => :darker_target, :fps => :fps))
            t, ij = track(file; kwargs..., diagnostic_file = joinpath(path, string(row.row_number, ".ts")))
            start_location = last(ij)
            # save_vid(results_dir, row.tij_file, file, t, ij)
            CSV.write(joinpath(results_dir, row.tij_file), DataFrame(t = t, i = first.(Tuple.(ij)), j = last.(Tuple.(ij))))
            next!(p)
            return start_location
        end


        # @info "update dosecond"
        for (row, start_location) in zip(eachrow(dofirst), start_locations)
            rows2update = subset(dosecond, :start_location => ByRow(==(row.row_uuid)), view = true, skipmissing = true)
            rows2update.start_location .= start_location
        end


        # # @info "restricting the union type of start_location"
        # dosecond.start_location = convert(Vector{Union{Missing, Tuple{Int, Int}}}, dosecond.start_location)

        # @info "started dosecond"
        # tforeach(eachrow(dosecond)) do row # Elins inner data took 28 minutes threaded, and 1 hr and 40 minutes on a single thread
        Threads.@threads for row in eachrow(dosecond)
            file = joinpath(data_path, row.runs_path, row.file)
            kwargs = omit_missing(row, (:runs_start => :start, :runs_stop => :stop, :target_width => :target_width, :start_location => :start_location, :window_size => :window_size, :darker_target => :darker_target, :fps => :fps))
            t, ij = track(file; kwargs..., diagnostic_file = joinpath(path, string(row.row_number, ".ts")))
            # save_vid(results_dir, row.tij_file, file, t, ij)
            CSV.write(joinpath(results_dir, row.tij_file), DataFrame(t = t, i = first.(Tuple.(ij)), j = last.(Tuple.(ij))))
            next!(p)
        end
        file_list = join((joinpath(path, string(row_number, ".ts")) for row_number in runs.row_number), '|')
        out = joinpath(results_dir, "diagnostic.mp4")
        run(`ffmpeg -y -loglevel 8 -i "concat:$file_list" -c copy $out`)
    end
    finish!(p)

    CSV.write(joinpath(results_dir, "runs.csv"), rename(select(runs, Not(:csv_source, :row_uuid)), :file => :runs_file))
    # @info "done!"
end

