# currently, start_location can be: 
# missing => center of the frame
# Tuple(Int, Int) => coordinate of where in th frame
# Int => row number of where 
function get_runs_df(data_path)
    files = get_all_csv(data_path, "run")
    tbl = CSV.File(files; source = :csv_source, stripwhitespace = true)
    df = DataFrame(tbl)
    fix_issue_1146!(df, files)
    return df
end

function massage!(runs, data_path)
    # prepare the df for the start_location is an Int
    runs.uuid .= [uuid4() for _ in 1:nrow(runs)]
    runs.start_location = convert(Vector{Union{Missing, Tuple{Int, Int}, Int, UUID}}, runs.start_location)
    for g in groupby(runs, :csv_source), row in eachrow(g)
        if row.start_location isa Int
            row.start_location = g.uuid[row.start_location]
        end
    end

    # useful for naming the diagnostic videos
    runs.row_number .= 1:nrow(runs)

    # recording_datetime
    transform!(runs, [:runs_path, :file] => ByRow((p, f) -> joinpath(data_path, p, f)) => :fullfile)
    transform!(groupby(runs, :fullfile), :fullfile => get_recording_datetime ∘ first => :recording_datetime)

    # start_datetime
    transform!(runs, [:recording_datetime, :runs_start] => ByRow(Missings.passmissing((dt, s) -> dt + Second(round(Int, s)))) => :start_datetime)

    # # this needs to move to analysis
    # transform!(runs, [:start_datetime, :station] => ByRow(get_sun_elevation_azimuth) => [:elevation, :azimuth])

end

function track_all(runs, results_dir, data_path)

    massage!(runs, data_path)

    # # TODO: rm
    # subset!(runs, :row_number => ByRow(∈(1:5)))


    dofirst = innerjoin(runs, select(runs, :start_location), on = :uuid => :start_location, matchmissing=:notequal)
    dosecond = antijoin(runs, select(runs, :start_location), on = :uuid => :start_location, matchmissing=:notequal)

    p = Progress(nrow(runs); desc = "Tracking all the runs:")
    # @info "started dofirst"
    start_locations = tmap(eachrow(dofirst)) do row
    # for row in eachrow(dofirst)
        # @info "doing row $(row.row_number)"
        # row_number, row = first(enumerate(eachrow(dofirst)))
        file = joinpath(data_path, row.runs_path, row.file)
        t, ij = track(file; start = row.runs_start, stop = row.runs_stop, start_location = row.start_location, target_width = row.target_width, window_size = row.window_size, fps = row.fps)
        start_location = last(ij)
        # save_vid(results_dir, row.row_number, file, t, ij)
        CSV.write(joinpath(results_dir, "$(row.row_number).csv"), DataFrame(t = t, i = first.(Tuple.(ij)), j = last.(Tuple.(ij))))
        next!(p)
        return start_location
    end


    # @info "update dosecond"
    for (row, start_location) in zip(eachrow(dofirst), start_locations)
        rows2update = subset(dosecond, :start_location => ByRow(==(row.uuid)), view = true, skipmissing = true)
        rows2update.start_location .= start_location
    end


    # # @info "restricting the union type of start_location"
    # dosecond.start_location = convert(Vector{Union{Missing, Tuple{Int, Int}}}, dosecond.start_location)

    # @info "started dosecond"
    tforeach(eachrow(dosecond)) do row # Elins inner data took 28 minutes threaded, and 1 hr and 40 minutes on a single thread
    # for row in eachrow(dosecond)
        # @info "doing row $(row.row_number)"
        file = joinpath(data_path, row.runs_path, row.file)
        # @info file
        t, ij = track(file; start = row.runs_start, stop = row.runs_stop, start_location = row.start_location, target_width = row.target_width, window_size = row.window_size, fps = row.fps)
        # save_vid(results_dir, row.row_number, file, t, ij)
        CSV.write(joinpath(results_dir, "$(row.row_number).csv"), DataFrame(t = t, i = first.(Tuple.(ij)), j = last.(Tuple.(ij))))
        next!(p)
    end
    finish!(p)

    CSV.write(joinpath(results_dir, "runs.csv"), rename(select(runs, Not(:csv_source)), :file => :runs_file))
    # @info "done!"
end



#
# df1 = subset(df, :start_location => ByRow(x -> isa(x, UUID)), view = true)
#
# tforeach(eachrow(df1)) do row
#     file = joinpath(data_path, row.runs_path, row.file)
#     t, xy = track(file, tosecond(row.start), tosecond(row.stop); start_location = to_tuple(row.start_location))
#     save_vid(row.row, file, t, xy)
#     CSV.write("$(row.row).csv", DataFrame(t = t, x = first.(xy), y = last.(xy)))
#     row.last_location = last(xy)
# end
#
#
#
#
#
#
#
#
#
# using Dates
# using XLSX, CSV, DataFrames, SimpTrack, OhMyThreads
# using VideoIO, ImageCore, ImageTransformations, ImageDraw
#
# include("functions.jl")
# include("quality.jl")
# include("types.jl")
# dir = "/home/yakir/mnt/dacke_lab_data/Data/Elin"
# df = get_all_tables(dir, "run")
#
# uuids = skipmissing(df.start_location)
# runs = Run[]
# for row in eachrow(df)
#     if row.id ∉ uuids
#         push!(runs, Run(df, row.root, row.runs_path, row.file, row.start, row.stop, row.start_location))
#     end
# end
#
# tforeach(runs) do run
#     t, xy = track(file, tosecond(row.start), tosecond(row.stop); start_location = df.last_location[row.start_location])
#     save_vid(row.row, file, t, xy)
#     CSV.write("$(row.row).csv", DataFrame(t = t, x = first.(xy), y = last.(xy)))
# end
#
#
# # data_path = "/home/yakir/mnt/dacke_lab_data/Data/Elin/Project_AllotheticVsIdiothetic_outdoors/"
# # runs_file = joinpath(data_path, "runs_outdoors.xlsx")
#
#
#
# quality(df)
#
#
# # defaults = Dict("n_corners" => (type = String, value = "(5, 8)"), "checker_size" => (type = Float64, value = 3.9), "temporal_step" => (type = Float64, value = 2))
# # for (name, (type, value)) in defaults
# #     if name ∉ names(df)
# #         df[!, name] = missings(type, nrow(df))
# #     else
# #         df[!, name] = convert(Vector{Union{Missing, type}}, df[!, name])
# #     end
# # end
# # for (c, (type, value)) in defaults
# #     replace!(df[!, c], missing => value)
# # end
#
#
# # df.start_location = convert(Vector{Union{Missing, Int, String}}, df.start_location)
# # df.row .= 1:nrow(df)
#
# df.last_location .= missing
# df.last_location = convert(Vector{Union{Missing, Tuple{Int, Int}}}, df.last_location)
#
# df1 = subset(df, :start_location => ByRow(x -> !isa(x, Int)), view = true)
# tforeach(eachrow(df1)) do row
#     file = joinpath(data_path, row.runs_path, row.file)
#     t, xy = track(file, tosecond(row.start), tosecond(row.stop); start_location = to_tuple(row.start_location))
#     save_vid(row.row, file, t, xy)
#     CSV.write("$(row.row).csv", DataFrame(t = t, x = first.(xy), y = last.(xy)))
#     row.last_location = last(xy)
# end
#
# df2 = subset(df, :start_location => ByRow(x -> isa(x, Int)), view = true)
# tforeach(eachrow(df2)) do row
#     file = joinpath(data_path, row.runs_path, row.file)
#     t, xy = track(file, tosecond(row.start), tosecond(row.stop); start_location = df.last_location[row.start_location])
#     save_vid(row.row, file, t, xy)
#     CSV.write("$(row.row).csv", DataFrame(t = t, x = first.(xy), y = last.(xy)))
# end
