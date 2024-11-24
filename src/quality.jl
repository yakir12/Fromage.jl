function calib_quality(df, data_path)
    nonmissing_columns = ("calibration_id", "path", "file", "start", "stop", "extrinsic")
    if isempty(df)
        @error "the table shouldn't be empty"
    end
    for column in nonmissing_columns
        if column ∉ names(df)
            @error "column $column missing from all calibration files"
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
        if row.start > row.stop 
            @error "stop shouldn't come before start in row $row"
        end
        file = joinpath(data_path, row.path, row.file)
        if !isfile(file)
            @error "video file $file shouldn't be missing, in $(row.csv_source)"
        end
        t = VideoIO.get_duration(file)
        if tosecond(row.start) > t 
            @error "start shouldn't occur after the video ends"
        end
        if tosecond(row.stop) > t 
            @error "stop shouldn't occur after the video ends"
        end
        if tosecond(row.extrinsic) > t 
            @error "stop shouldn't occur after the video ends"
        end
        if !ismissing(row.checker_size) && row.checker_size ≤ 0
            @error "checker_size should be positive in row $row"
        end
        if !ismissing(row.n_corners)
            x, y = to_tuple(row.n_corners)
            if x ≤ 0 || y ≤ 0
                @error "n_corners should be positive in row $row"
            end
        end
        if !ismissing(row.temporal_step) && row.temporal_step ≤ 0
            @error "temporal_step should be positive in row $row"
        end
    end
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
    nonmissing_columns = ("path", "file", "start", "stop", "calibration_id")
    if isempty(df)
        @error "the table shouldn't be empty"
    end
    for column in nonmissing_columns
        if column ∉ names(df)
            @error "column $column missing from all calibration files"
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
    if any(x -> isa(x, Int), df.start_location)
        for g in groupby(df, :csv_source), row in eachrow(g)
            if row.start_location isa Int && row.start_location > nrow(g)
                @error """Hmm... there is a start_location that refers to a non existant run in $(row.csv_source). See row:
                $row"""
            end
        end
    end
    @showprogress "Checking the quality of the run csv data:" for row in eachrow(df)
        if row.start > row.stop 
            @error "stop shouldn't come before start in row $row"
        end
        file = joinpath(data_path, row.path, row.file)
        if !isfile(file)
            @error "video file $file shouldn't be missing, in $(row.csv_source)"
        end
        t = VideoIO.get_duration(file)
        if tosecond(row.start) > t 
            @error "start shouldn't occur after the video ends in row $row"
        end
        if tosecond(row.stop) > t 
            @error "stop shouldn't occur after the video ends in row $row"
        end
        if row.object_width ≤ 0
            @error "object width shouldn't be equal to or smaller than zero in row $row"
        end
    end
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
