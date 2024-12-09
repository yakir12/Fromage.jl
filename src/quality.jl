function tuple_check(row, column)
    if !ismissing(row[column]) && !occursin(r"^\((\d+),\s*(\d+)\)$", row[column])
        @error """$column should be a tuple of integers (e.g. "(1,2)") in row $row"""
    end
end

function mandatory_quality(df, nonmissing_columns)
    if isempty(df)
        @error "the table shouldn't be empty"
    end
    for column in nonmissing_columns
        if column ∉ names(df)
            @error "column $column missing from all files"
        end
        try
            disallowmissing(df, Cols(nonmissing_columns...), error = true)
        catch ex
            if ex isa ArgumentError
                @error "column $column should not contain any missing data"
            else
                throw(ex)
            end
        end
    end
end

function calib_quality(df, data_path)

    nonmissing_columns = ("file", "extrinsic")
    mandatory_quality(df, nonmissing_columns)

    transform!(df, :extrinsic => ByRow(tosecond); renamecols = false)

    columns = ("center", "north", "calibs_path", "checker_size", "n_corners", "temporal_step")
    coalesce_df!(df, columns)

    transform!(df, [:calibs_path, :file] => ByRow((p, f) -> joinpath(data_path, p, f)) => :fullfile)

    for file in df.fullfile
        if !isfile(file)
            @error "video file $file shouldn't be missing"
        end
    end

    transform!(df, :fullfile => ByRow(VideoIO.get_duration) => :duration)

    column = "calibs_start"
    if column ∉ names(df)
        df[!, column] .= missing
    end
    df[!, column] .= tosecond.(coalesce.(df[!, column], @load_preference(column, 0)))

    column = "calibs_stop"
    if column ∉ names(df)
        df[!, column] .= missing
    end
    df[!, column] .= tosecond.(coalesce.(df[!, column], @load_preference(column, missing), df.duration))

    column = "calibration_id"
    if column ∉ names(df)
        df[!, column] .= missing
    end
    df[!, column] .= coalesce.(df[!, column], joinpath.(df.calibs_path, df.file))

    if !allunique(df.calibration_id)
        res = combine(groupby(select(subset(transform(groupby(df, :calibration_id), nrow), :nrow => ByRow(>(1))), :csv_source, :calibration_id), :calibration_id), :csv_source => Ref => :csv_source)
        io = IOBuffer()
        println(io, "Calibration IDs should be identical.")
        for row in eachrow(res)
            println(io, "calibration_id: $(row.calibration_id) is repeated in:")
            for (i, csv_source) in enumerate(row.csv_source)
                println(io, "\t $i. $csv_source")
            end
        end
        msg = String(take!(io))
        @error msg
    end

    @showprogress "Checking the quality of the calibration csv data:" for row in eachrow(df)
        if row.calibs_start > row.calibs_stop
            @error "stop shouldn't come before start in row $row"
        end
        if row.calibs_start > row.duration
            @error "start shouldn't occur after the video ends"
        end
        if row.calibs_stop > row.duration
            @error "stop shouldn't occur after the video ends"
        end
        if row.extrinsic > row.duration
            @error "stop shouldn't occur after the video ends"
        end
        if !ismissing(row.checker_size) && row.checker_size ≤ 0
            @error "checker_size should be positive in row $row"
        end
        for column in (:n_corners, :center, :north)
            tuple_check(row, column)
        end
        if !ismissing(row.temporal_step) && row.temporal_step ≤ 0
            @error "temporal_step should be positive in row $row"
        end
    end

    transform!(df, [:center, :north, :n_corners] .=> ByRow(to_tuple); renamecols = false)

    return nothing
end

function coalesce_df!(df, columns)
    for column in columns
        if column ∉ names(df)
            df[!, column] .= @load_preference(column, missing)
        else
            df[!, column] .= coalesce.(df[!, column], @load_preference(column, missing))
        end
    end
end

function runs_quality(df, data_path)
    nonmissing_columns = ("file", "calibration_id")
    mandatory_quality(df, nonmissing_columns)

    columns = ("runs_path", "start_xy", "target_width", "window_size")
    coalesce_df!(df, columns)

    transform!(df, [:runs_path, :file] => ByRow((p, f) -> joinpath(data_path, p, f)) => :fullfile)

    for file in df.fullfile
        if !isfile(file)
            @error "video file $file shouldn't be missing"
        end
    end

    transform!(df, :fullfile => ByRow(VideoIO.get_duration) => :duration)


    column = "runs_start"
    if column ∉ names(df)
        df[!, column] .= missing
    end
    df[!, column] .= tosecond.(coalesce.(df[!, column], @load_preference(column, 0)))

    column = "runs_stop"
    if column ∉ names(df)
        df[!, column] .= missing
    end
    df[!, column] .= tosecond.(coalesce.(df[!, column], @load_preference(column, missing), df.duration))

    if any(x -> isa(x, Int), df.start_xy)
        for g in groupby(df, :csv_source), row in eachrow(g)
            if isa(row.start_xy, Int) && row.start_xy > nrow(g)
                @error """Hmm... there is a start_xy that refers to a non existant run in $(row.csv_source). See row:
                $row"""
            end
        end
    end
    @showprogress "Checking the quality of the run csv data:" for row in eachrow(df)
        if row.runs_start > row.runs_stop 
            @error "stop shouldn't come before start in row $row"
        end
        if row.runs_start > row.duration
            @error "start shouldn't occur after the video ends in row $row"
        end
        if row.runs_stop > row.duration
            @error "stop shouldn't occur after the video ends in row $row"
        end
        if row.target_width ≤ 0
            @error "target width shouldn't be equal to or smaller than zero in row $row"
        end
        tuple_check(row, :window_size)
        if !ismissing(row.start_xy) && !isa(row.start_xy, Int)
            tuple_check(row, :window_size)
        end
    end

    transform!(df, :start_xy => ByRow(to_tuple); renamecols = false)

    return nothing
end

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
