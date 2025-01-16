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
    transform!(runs, [:recording_datetime, :runs_start] => ByRow(Missings.passmissing((dt, s) -> dt + Second(round(Int, s)))) => :start_datetime)

    # # this needs to move to analysis
    # transform!(runs, [:start_datetime, :station] => ByRow(get_sun_elevation_azimuth) => [:elevation, :azimuth])

end

function track_all(runs, results_dir, data_path)

    massage!(runs, data_path)

    # # TODO: rm
    # subset!(runs, :run_id => ByRow(==(54)))


    dofirst = innerjoin(runs, select(runs, :start_location), on = :row_uuid => :start_location, matchmissing=:notequal)
    dosecond = antijoin(runs, select(runs, :start_location), on = :row_uuid => :start_location, matchmissing=:notequal)

    p = Progress(nrow(runs); desc = "Tracking all the runs:")
    # @info "started dofirst"
    start_locations = tmap(eachrow(dofirst)) do row
    # for row in eachrow(dofirst)
        # @info "doing row $(row.row_number)"
        # row_number, row = first(enumerate(eachrow(dofirst)))
        file = joinpath(data_path, row.runs_path, row.file)
	kwargs = omit_missing(row, (:start, :stop, :target_width, :start_location, :window_size, :darker_target, :fps))
	t, ij = track(file; kwargs...)
        start_location = last(ij)
        # save_vid(results_dir, row.row_number, file, t, ij)
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
    tforeach(eachrow(dosecond)) do row # Elins inner data took 28 minutes threaded, and 1 hr and 40 minutes on a single thread
    # for row in eachrow(dosecond)
        file = joinpath(data_path, row.runs_path, row.file)
	kwargs = omit_missing(row, (:start, :stop, :target_width, :start_location, :window_size, :darker_target, :fps))
	t, ij = track(file; kwargs...)
        # save_vid(results_dir, row.row_number, file, t, ij)
        CSV.write(joinpath(results_dir, row.tij_file), DataFrame(t = t, i = first.(Tuple.(ij)), j = last.(Tuple.(ij))))
        next!(p)
    end
    finish!(p)

    CSV.write(joinpath(results_dir, "runs.csv"), rename(select(runs, Not(:csv_source, :row_uuid)), :file => :runs_file))
    # @info "done!"
end

