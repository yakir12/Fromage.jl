# currently, start_location can be: 
# missing => center of the frame
# Tuple(Int, Int) => coordinate of where in th frame
# Int => row number of where 
function get_runs_df(data_path, calibs)
    files = get_all_csv(data_path, "run")
    tbl = CSV.File(files; source = :csv_source, stripwhitespace = true)
    df = DataFrame(tbl)
    fix_issue_1146!(df, files)
    coalesce_df!(df, ("start_location", "object_width"))
    runs_quality(df, data_path)

    df.uuid .= [uuid4() for _ in 1:nrow(df)]
    df.start_location = Union{Tuple{Int, Int}, Missing, Int, UUID}[to_tuple(x) for x in df.start_location]
    for g in groupby(df, :csv_source), row in eachrow(g)
        if row.start_location isa Int
            row.start_location = g.uuid[row.start_location]
        end
    end
    leftjoin!(df, select(calibs, Cols(:calibration_id, :center)), on = :calibration_id)
    transform!(df, :center => ByRow(to_tuple) => :start_location)
    # select!(df, Not(:index))
    df.run_number .= 1:nrow(df)
    return df
end

function track_all(df, results_dir, data_path)

    # subset!(df, :run_number => ByRow(x -> 34 < x < 38))

    dofirst = innerjoin(df, select(df, :start_location), on = :uuid => :start_location, matchmissing=:notequal)
    dosecond = antijoin(df, select(df, :start_location), on = :uuid => :start_location, matchmissing=:notequal)

    p = Progress(nrow(df), "Tracking all the runs:")
    # @info "started dofirst"
    tforeach(eachrow(dofirst)) do row
    # for row in eachrow(dofirst)
        # @info "doing row $(row.run_number)"
        # run_number, row = first(enumerate(eachrow(dofirst)))
        file = joinpath(data_path, row.path, row.file)
        t, xy = track(file, tosecond(row.start), tosecond(row.stop); start_location = row.start_location, object_width = row.object_width)
        save_vid(results_dir, row.run_number, file, t, xy)
        CSV.write(joinpath(results_dir, "$(row.run_number).csv"), DataFrame(t = t, x = first.(xy), y = last.(xy)))
        next!(p)
    end

    # @info "update dosecond"
    for row in eachrow(dofirst)
        rows2update = subset(dosecond, :start_location => ByRow(==(row.uuid)), view = true, skipmissing = true)
        xyts = CSV.read(joinpath(results_dir, "$(row.run_number).csv"), DataFrame)
        xy = (xyts.x[end], xyts.y[end])
        rows2update.start_location .= Ref(xy)
    end

    # @info "restricting the union type of start_location"
    dosecond.start_location = Union{Missing, Tuple{Int, Int}}[x for x in dosecond.start_location]

    # @info "started dosecond"
    tforeach(eachrow(dosecond)) do row
    # for row in eachrow(dosecond)
        # @info "doing row $(row.run_number)"
        file = joinpath(data_path, row.path, row.file)
        t, xy = track(file, tosecond(row.start), tosecond(row.stop); start_location = row.start_location, object_width = row.object_width)
        save_vid(results_dir, row.run_number, file, t, xy)
        CSV.write(joinpath(results_dir, "$(row.run_number).csv"), DataFrame(t = t, x = first.(xy), y = last.(xy)))
        next!(p)
    end
    finish!(p)

    CSV.write(joinpath(results_dir, "runs.csv"), select(df, Not(:path, :file, :start, :stop, :start_location, :object_width, :uuid, :csv_source)))
    # @info "done!"
end



#
# df1 = subset(df, :start_location => ByRow(x -> isa(x, UUID)), view = true)
#
# tforeach(eachrow(df1)) do row
#     file = joinpath(data_path, row.path, row.file)
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
#         push!(runs, Run(df, row.root, row.path, row.file, row.start, row.stop, row.start_location))
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
#     file = joinpath(data_path, row.path, row.file)
#     t, xy = track(file, tosecond(row.start), tosecond(row.stop); start_location = to_tuple(row.start_location))
#     save_vid(row.row, file, t, xy)
#     CSV.write("$(row.row).csv", DataFrame(t = t, x = first.(xy), y = last.(xy)))
#     row.last_location = last(xy)
# end
#
# df2 = subset(df, :start_location => ByRow(x -> isa(x, Int)), view = true)
# tforeach(eachrow(df2)) do row
#     file = joinpath(data_path, row.path, row.file)
#     t, xy = track(file, tosecond(row.start), tosecond(row.stop); start_location = df.last_location[row.start_location])
#     save_vid(row.row, file, t, xy)
#     CSV.write("$(row.row).csv", DataFrame(t = t, x = first.(xy), y = last.(xy)))
# end
