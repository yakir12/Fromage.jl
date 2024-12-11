# function tuple_check(row, column)
#     if !ismissing(row[column]) && !occursin(r"^\((\d+),\s*(\d+)\)$", row[column])
#         @error """$column should be a tuple of integers (e.g. "(1,2)") in row $row"""
#     end
# end

function test_mandatory_quality(df, io, nonmissing_columns)
    if isempty(df)
        println(io, "the table shouldn't be empty")
    end
    for column in nonmissing_columns
        if column ∉ names(df)
            println(io, "column $column missing from all files")
        end
        try
            disallowmissing(df, column, error = true)
        catch ex
            if ex isa ArgumentError
                println(io, "column $column should not contain any missing data" df)
            else
                throw(ex)
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

    # checks for minimal requirements
    nonmissing_columns = ("file", "extrinsic")
    test_mandatory_quality(df, nonmissing_columns)

    # fill in missing values
    for column in keys(runs_preferences)
        coalesce_df!(df, String(column), missing)
    end
    coalesce_df!(df, "calibration_id", 1:nrow(df))

    # parse values to correct format
    transform!(df,
               [:calibs_start, :calibs_stop, :extrinsic] .=> ByRow(tosecond), 
               [:file, :calibs_path, :calibration_id] .=> ByRow(String), 
               [:center, :north, :n_corners] .=> ByRow(to_tuple),
               :checker_size => ByRow(Float64); renamecols = false)

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
    @showprogress "Checking the quality of the calibration csv data:" for row in eachrow(df)
        file = joinpath(data_path, row.calibs_path, row.file)
        if !isfile(file)
            println(io, "video file $file shouldn't be missing")
        end
        if row.calibs_start > row.calibs_stop
            println(io, "stop shouldn't come before start in row $row")
        end
    end

    return nothing
end

function runs_quality!(df, io, data_path)

    # checks for minimal requirements
    nonmissing_columns = ("file", "calibration_id")
    test_mandatory_quality(df, nonmissing_columns)

    # fill in missing values
    for column in keys(calibs_preferences)
        coalesce_df!(df, String(column), missing)
    end

    # parse values to correct format
    transform!(df,
               [:runs_start, :runs_stop] .=> ByRow(tosecond), 
               [:file, :runs_path, :calibration_id, :station] .=> ByRow(String), 
               [:window_size, :start_xy] .=> ByRow(to_tuple),
               :target_width => ByRow(Float64); renamecols = false)

    # verification tests
    if any(x -> isa(x, Int), df.start_xy)
        for g in groupby(df, :csv_source), row in eachrow(g)
            if isa(row.start_xy, Int) && row.start_xy > nrow(g)
                println(io, """Hmm... there is a start_xy that refers to a non existant run in $(row.csv_source). See row:
                        $row""")
            end
        end
    end
    @showprogress "Checking the quality of the run csv data:" for row in eachrow(df)
        file = joinpath(data_path, row.runs_path, row.file)
        if !isfile(file)
            println(io, "video file $file shouldn't be missing")
        end
        if row.runs_start > row.runs_stop 
            println(io, "stop shouldn't come before start in row $row")
        end
        if !ismissing(row.station) && !haskey(STATIONS, row.station)
            println(io, "Station $(row.station) should be one of the registered stations")
        end
    end

    return nothing
end

function both_quality!(calibs, io, runs)
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
     return nothing
end





# function runs_quality(df, data_path)
#     nonmissing_columns = ("file", "calibration_id")
#     mandatory_quality(df, nonmissing_columns)
#
#     columns = ("runs_start", "runs_stop", "runs_path", "start_xy", "target_width", "window_size", "station")
#     coalesce_df!(df, columns)
#
#     transform!(df, [:runs_start, :runs_stop] .=> ByRow(tosecond); renamecols = false)
#
#     if any(x -> isa(x, Int), df.start_xy)
#         for g in groupby(df, :csv_source), row in eachrow(g)
#             if isa(row.start_xy, Int) && row.start_xy > nrow(g)
#                 @error """Hmm... there is a start_xy that refers to a non existant run in $(row.csv_source). See row:
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
#         if !ismissing(row.start_xy) && !isa(row.start_xy, Int)
#             tuple_check(row, :start_xy)
#         end
#         if !ismissing(row.station) && !haskey(STATIONS, row.station)
#             @error "Station $(row.station) should be one of the registered stations"
#         end
#     end
#
#     transform!(df, [:start_xy, :window_size] .=> ByRow(to_tuple); renamecols = false)
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
