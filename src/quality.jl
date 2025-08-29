# function tuple_check(row, column)
#     if !ismissing(row[column]) && !occursin(r"^\((\d+),\s*(\d+)\)$", row[column])
#         @error """$column should be a tuple of integers (e.g. "(1,2)") in row $row"""
#     end
# end

function test_mandatory_quality(df, nonmissing_columns)
    if isempty(df)
        @error """all the csv files are empty!"""
    end
    for column in nonmissing_columns
        if column ∉ names(df)
            @error """column "$column" shouldn't be missing from all the files"""
        end
        df1 = subset(df, column => ByRow(ismissing))
        if !isempty(df1)
            for (k, grp) in pairs(groupby(df1, :csv_source))
                file = string(k.csv_source)
                rows = join(grp.row_number, ',')
                @error """in file "$file", rows: $rows, the column "$column" cannot be empty/missing"""
            end
        end
    end
end

function coalesce_df!(df, column, default)
    if column ∉ names(df)
        df[!, column] .= missing
    end
    df[!, column] .= coalesce.(df[!, column], @load_preference(column, missing), default)
end

function calib_quality!(df, io, data_path)

    transform!(groupby(df, :csv_source), eachindex => :row_number)

    # checks for minimal requirements
    nonmissing_columns = ("file", "extrinsic")
    test_mandatory_quality(df, nonmissing_columns)

    # fill in missing values
    for column in keys(calibs_preferences)
        coalesce_df!(df, String(column), missing)
    end
    coalesce_df!(df, "calibration_id", 1:nrow(df))
    coalesce_df!(df, "calibs_path", get_default_relpath.(data_path, df.csv_source))

    # parse values to correct format
    transform!(df,
               [:calibs_start, :calibs_stop, :extrinsic] .=> ByRow(tosecond), 
               [:file, :calibs_path, :calibration_id] .=> ByRow(string), 
               [:center, :north, :n_corners] .=> ByRow(to_tuple),
               [:checker_size, :temporal_step] .=> ByRow(tofloat),
               :radial_parameters => ByRow(Int),
               ; renamecols = false)

    # verification tests
    if !allunique(df.calibration_id)
        res = combine(groupby(select(subset(transform(groupby(df, :calibration_id), nrow), :nrow => ByRow(>(1))), :csv_source, :calibration_id), :calibration_id), :csv_source => Ref => :csv_source)
        println(io, "Calibration IDs should be identical.")
        for row in eachrow(res)
            println(io, "calibration_id: $(row.calibration_id) is repeated in:")
            for (i, csv_source) in enumerate(row.csv_source)
                println(io, "\t $i. $csv_source")
            end
        end
    end

    throw_non_empty(io)

    transform!(df, [:calibs_path, :file] => ByRow((p, f) -> joinpath(data_path, p, f)) => :calibs_fullfile)

    @showprogress "Checking the quality of the calibration csv data:" for row in eachrow(df)
        file = row.calibs_fullfile
        if !isfile(file)
            println(io, "video file $file shouldn't be missing")
        end
        if row.calibs_start > row.calibs_stop
            println(io, "stop shouldn't come before start in row $row")
        end
    end

    throw_non_empty(io)


    # recording_datetime
    transform!(groupby(df, :calibs_fullfile), [:calibs_fullfile, :type] => ((calibs_fullfile, type) -> type[1] == "matlab" ? fill(DateTime(0), length(type)) : fill(get_recording_datetime(calibs_fullfile[1]), length(calibs_fullfile))) => :calibs_recording_datetime)

    return nothing
end

function runs_quality!(df, io, data_path)

    transform!(groupby(df, :csv_source), eachindex => :row_number)

    # checks for minimal requirements
    nonmissing_columns = ("file", "calibration_id")
    test_mandatory_quality(df, nonmissing_columns)

    throw_non_empty(io)

    # fill in missing values
    for column in keys(runs_preferences)
        coalesce_df!(df, String(column), missing)
    end
    coalesce_df!(df, "runs_path", get_default_relpath.(data_path, df.csv_source))

    # fill in missing run_ids and make them globally unique
    coalesce_df!(df, "run_id", [uuid4() for _ in 1:nrow(df)])
    transform!(groupby(df, [:csv_source, :run_id]), groupindices => :temp_run_id)
    rename!(select!(df, Not(:run_id)), :temp_run_id => :run_id)

    # parse values to correct format
    transform!(df,
               [:runs_start, :runs_stop, :POI] .=> ByRow(passmissing(tosecond)), 
               [:file, :runs_path, :calibration_id] .=> ByRow(passmissing(string)), 
               [:window_size, :start_location] .=> ByRow(to_tuple), # TODO stupid that I use the same function to convert a coordinate start_location as well as a Int
               :target_width => ByRow(to_target_width); renamecols = false)

    # verification tests
    # this test is unessesary. I'm just gonna assume that the order of subsequent rows for the same run_id are ment to be chained
    # if any(x -> isa(x, Int), df.start_location)
    #     for g in groupby(df, :csv_source), row in eachrow(g)
    #         if isa(row.start_location, Int) && row.start_location > nrow(g)
    #             println(io, """Hmm... there is a start_location that refers to a non existant run in $(row.csv_source). See row:
    #                     $row""")
    #         end
    #     end
    # end
    transform!(df, [:runs_path, :file] => ByRow((p, f) -> joinpath(data_path, p, f)) => :runs_fullfile)



    df1 = subset(df, [:runs_start, :runs_stop] => ByRow(≥))
    if !isempty(df1)
        for (k, grp) in pairs(groupby(df1, :csv_source))
            file = string(k.csv_source)
            rows = join(grp.row_number, ',')
            @error """in file "$file", rows: $rows, "runs_start" shouldn't be equal or come after "runs_stop" """
        end
    end
    @showprogress "Checking the quality of the run csv data:" for row in eachrow(df)
        file = row.runs_fullfile
        if !isfile(file)
            println(io, "video file $file shouldn't be missing")
        end
        # if !ismissing(row.station) && !haskey(STATIONS, row.station)
        #     println(io, "Station $(row.station) should be one of the registered stations")
        # end
    end
    throw_non_empty(io)
    
    # recording_datetime
    transform!(groupby(df, :runs_fullfile), :runs_fullfile => get_recording_datetime ∘ first => :runs_recording_datetime)

    return nothing
end

function both_quality!(calibs, io, runs, data_path)
    u_runs_calibration_id = unique(runs.calibration_id)
    bad = false
    for row in eachrow(calibs)
        if row.calibration_id ∉ u_runs_calibration_id
            bad = true
            @warn "calibration ID, $(row.calibration_id), is in the calibs.csv file, $(row.csv_source), but not in any of the runs.csv file/s. Ignoring the extra calibrations!"
        end
    end
    if bad
        subset!(calibs, :calibration_id => ByRow(∈(u_runs_calibration_id)))
    end
    for id in u_runs_calibration_id
        if id ∉ calibs.calibration_id
            println(io, "calibration ID, $id, is in the runs.csv file, but not in any of the calibs.csv file/s")
        end
    end

    df = leftjoin(rename(select(runs, Cols(:csv_source, :run_id, :calibration_id, :runs_recording_datetime)), :csv_source => :runs_csv_source), rename(select(calibs, Cols(:csv_source, :calibration_id, :calibs_recording_datetime)), :csv_source => :calibs_csv_source), on = :calibration_id)
    if all(ismissing, df.calibs_csv_source)
        @error "none of the calibrations match with the runs. None of the calibration_ids match."
    end
    throw_non_empty(io)
    transform!(df, Cols(:runs_recording_datetime, :calibs_recording_datetime) => ByRow(-) => :diff)

    subset!(df, :diff => ByRow(>(Day(1))))
    if !isempty(df)
        select!(df, Cols(:runs_csv_source, :run_id, :calibs_csv_source, :calibration_id))
        @warn "There are runs with calibrations that were not recorded on the same day:"
        println(df)
    end

    # replace missing start_location with center
    leftjoin!(runs, select(calibs, Cols(:calibration_id, :center)), on = :calibration_id)
    runs.start_location .= coalesce.(runs.start_location, runs.center)
    select!(runs, Not(:center))

    files = unique([joinpath.(runs.runs_path, runs.file); joinpath.(calibs.calibs_path, calibs.file)])
    others = get_all_other(data_path)

    Δ = setdiff(others, files)

    if !isempty(Δ)
        @warn "the following files are not used:"
        println.(Δ)
    end


    return nothing
end





# function runs_quality(df, data_path)
#     nonmissing_columns = ("file", "calibration_id")
#     mandatory_quality(df, nonmissing_columns)
#
#     columns = ("runs_start", "runs_stop", "runs_path", "start_location", "target_width", "window_size", "station")
#     coalesce_df!(df, columns)
#
#     transform!(df, [:runs_start, :runs_stop] .=> ByRow(tosecond); renamecols = false)
#
#     if any(x -> isa(x, Int), df.start_location)
#         for g in groupby(df, :csv_source), row in eachrow(g)
#             if isa(row.start_location, Int) && row.start_location > nrow(g)
#                 @error """Hmm... there is a start_location that refers to a non existant run in $(row.csv_source). See row:
#                 $row"""
#             end
#         end
#     end
#     @showprogress "Checking the quality of the run csv data:" for row in eachrow(df)
#         file = joinpath(data_path, row.runs_path, row.file)
#         if !isfile(file)
#             @error "video file $file shouldn't be missing"
#         end
#         if row.runs_start > row.runs_stop 
#             @error "stop shouldn't come before start in row $row"
#         end
#         if row.target_width ≤ 0
#             @error "target width shouldn't be equal to or smaller than zero in row $row"
#         end
#         tuple_check(row, :window_size)
#         if !ismissing(row.start_location) && !isa(row.start_location, Int)
#             tuple_check(row, :start_location)
#         end
#         if !ismissing(row.station) && !haskey(STATIONS, row.station)
#             @error "Station $(row.station) should be one of the registered stations"
#         end
#     end
#
#     transform!(df, [:start_location, :window_size] .=> ByRow(to_tuple); renamecols = false)
#
#     return nothing
# end

# function intersection_quality(calibs, runs)
# TODO: things that have to do with the intersection of both: like are all calibration IDs in calib etc
#
#     res = combine(groupby(select(subset(transform(groupby(df, :calibration_id), nrow), :nrow => ByRow(>(1))), :csv_source, :calibration_id), :calibration_id), :csv_source => Ref => :csv_source)
#     io = IOBuffer()
#     println(io, "Calibration IDs should be identical.")
#     for row in eachrow(res)
#         println(io, "calibration_id: $(row.calibration_id) is repeated in:")
#         for (i, csv_source) in enumerate(row.csv_source)
#             println(io, "\t $i. $csv_source")
#         end
#     end
#     msg = String(take!(io))
#     @error msg
# end
#
#
#
#
#
# urid = unique(runs.calibration_id)
# i = finall(id -> id ∉ calib.calibration_id, urid)
# if !isempty(i)
#     io = IOBuffer()
#     println(io, "The following calibration_ids are in the runs.csv file/s but are missing from the calib.csv file/s:")
#     for j in i
#         println(io, "calibration_id: $(urid[j]) is repeated in:")
#         for (i, csv_source) in enumerate(row.csv_source)
#             println(io, "\t $i. $csv_source")
#         end
#     end
#     msg = String(take!(io))
#     @error msg
# end
#
#
# if any(id -> id ∉ unique(runs.calibration_id), calib.calibration_id)
#     @warn "there are calibration_ids in the calib.csv file that are not used in the runs files"
# end
