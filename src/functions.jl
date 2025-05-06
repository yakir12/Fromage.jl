# function read_xlsx(file)
#     f = XLSX.readxlsx(file)
#     sheet = first(XLSX.sheetnames(f))
#     io = IOBuffer()
#     CSV.write(io, DataFrame(XLSX.gettable(f[sheet])))
#     CSV.read(take!(io), DataFrame)
# end

function get_recording_datetime(file)
    # txts = strip.(split(read(`$exiftool -T -AllDates -n $file`, String), '\t'))
    txts = strip.(split(read(`exiftool -T -AllDates -n $file`, String), '\t'))
    dts = [DateTime(txt[1:19], DateFormat("yyyy:mm:dd HH:MM:SS")) for txt in txts if length(txt) > 18 && txt[1:19] ≠ "0000:00:00 00:00:00"]
    if isempty(dts)
        return missing
    else
        minimum(dts)
    end
end

# omit_missing(row, ks) = (kwarg => row[key] for (key, kwarg) in ks if haskey(row, key) && !ismissing(row[key]))

get_default_relpath(data_path, csv_source) = dirname(relpath(csv_source, data_path))

function get_all_other(dir)
    files = String[]
    r = Regex("^.*[calibs|runs].*\\.csv\$")
    for (root, _, _files) in walkdir(dir), file in _files
        if !occursin(r, file)
            full = joinpath(root, file)
            push!(files, last(split(full, dir))[2:end])
        end
    end
    return files
end

function get_all_csv(dir, type)
    files = String[]
    r = Regex("^.*$type.*\\.csv\$")
    for (root, _, _files) in walkdir(dir), file in _files
        if !startswith(file, '.') && occursin(r, file)
            push!(files, joinpath(root, file))
        end
    end
    return files
end

function get_df(data_path, type; kwargs...)
    files = get_all_csv(data_path, type)
    if isempty(files)
        error("no $type csv files found")
    end
    tbl = CSV.File(files; source = :csv_source, stripwhitespace = true, types = String, kwargs...)
    df = DataFrame(tbl)
    fix_issue_1146!(df, files)
    empty_columns = findall(c -> all(ismissing, c), eachcol(df))
    select!(df, Not(empty_columns...))
    return df
end

# function replace_with_uuid!(tbl)
#     if "start_location" ∈ names(tbl)
#         todo = subset(tbl, :start_location => ByRow(x -> isa(x, Int)); skipmissing = true, view = true)
#         transform!(todo, :start_location => ByRow(i -> tbl.id[i]), renamecols = false)
#     end
#     select!(tbl, Not(:index))
# end
#
#
# function get_all_tables(dir, type)
#
#     type = "run"
#     regex = Regex("^.*$type.*.csv\$")
#     sources = String[]
#     for (root, _, files) in walkdir(dir), file in files
#         if occursin(regex, file)
#             tbl = CSV.read(joinpath(root, file), DataFrame)
#             push!(sources, joinpath(root, file))
#         end
#     end
#
#     df = DataFrame(CSV.File(sources, types = Dict(:start => Time, :stop => Time), source = "source"))

# function get_all_runs(dir)
#     df = DataFrame(root = String[])
#     for (root, _, files) in walkdir(dir), file in files
#         if occursin(r"^.*run.*.csv\$", file)
#             tbl = CSV.read(joinpath(root, file), DataFrame; types = Dict(:start => Time, :stop => Time, :file => String))
#             transform!(tbl, :start => ByRow(_ -> uuid4()) => :id)
#             replace_with_uuid!(tbl)
#             tbl.root .= root
#             append!(df, tbl; cols = :union, promote = true)
#         end
#     end
#     disallowmissing!(df, Cols(:root, :path, :file, :start, :stop))
#     return df
# end
#
# function get_all_tables(dir, type)
#     regex = Regex("^.*$type.*.csv\$")
#     df = DataFrame(root = String[])
#     for (root, _, files) in walkdir(dir), file in files
#         if occursin(regex, file)
#             tbl = CSV.read(joinpath(root, file), DataFrame; types = Dict(:start => Time, :stop => Time))
#             transform!(tbl, :start => ByRow(_ -> uuid4()) => :id)
#             replace_with_uuid!(tbl)
#             tbl.root .= root
#             append!(df, tbl; cols = :union, promote = true)
#         end
#     end
#     disallowmissing!(df, Cols(:root, :path, :file, :start, :stop))
#     return df
# end


# function get_all_tables(dir, type)
#     regex = Regex(".*$type.*.(?:csv|xlsx)")
#     df = DataFrame(root = String[])
#     for (root, _, files) in walkdir(dir), file in files
#         fullfile = joinpath(root, file)
#         name, ext = splitext(file)
#         if occursin(type, name)
#             tbl = if ext == ".csv"
#                 CSV.read(fullfile, DataFrame)
#             elseif ext == ".xlsx" 
#                 read_xlsx(fullfile)
#             else # a file that has `type` in it, but isn't a table file
#                 continue
#             end
#             transform!(tbl, :start => ByRow(_ -> uuid4()) => :id)
#             replace_with_uuid!(tbl)
#             tbl.root .= root
#             append!(df, tbl; cols = :union, promote = true)
#         end
#     end
#     return df
# end

# for file in get_table_files(dir)
#     tbl = get_table(file)
#     if "run_id" ∈ names(tbl)
#         @show file
#     end
# end

# function get_duration(fullfile)
#     s = VideoIO.get_duration(fullfile)
#     Time(0) + Millisecond(1000floor(s, digits = 3))
# end

tofloat(x::AbstractString) = parse(Float64, x)
tofloat(x::Real) = Float64(x)

tobool(str::AbstractString) = parse(Bool, str)
tobool(x) = x

tosecond(t::T) where {T <: TimePeriod} = t / convert(T, Dates.Second(1))
tosecond(t::TimeType) = tosecond(t - Time(0))
tosecond(sec::Real) = sec
function tosecond(str::AbstractString) 
    if ',' ∈ str
        parse_string_time.(split(str, ','))
    else
        parse_string_time(str)
    end
end
parse_string_time(str::AbstractString) = ':' ∈ str ? tosecond(Time(str)) : parse(Float64, str)

function to_tuple(x::AbstractString)
    if contains(x, '(')
        m = match(r"^\((\d+),\s*(\d+)\)$", x)
        Tuple{Int, Int}(parse.(Int, m.captures))
    else
        parse(Int, x)
    end
end
to_tuple(x) = x

to_target_width(x::AbstractString) = parse(Float64, x)
to_target_width(x) = x

function save_vid(results_dir, name, file, ts, ij)
    start = first(ts)
    stop = last(ts)
    t = stop - start
    framerate_in = 1/step(ts)
    s = 4
    # fps = 1
    framerate_out = round(Int, t*framerate_in/2) # dunno why this is 5 seconds
    start -= step(ts)
    cmd = `$(ffmpeg()) -loglevel 8 -ss $start -i $file -t $t -r $framerate_in -vf "scale=iw/$s:ih/$s" -preset veryfast -f matroska -`
    openvideo(open(cmd)) do vid
        img = read(vid)
        open_video_out(joinpath(results_dir, "$name.mp4"), img; framerate = framerate_out, codec_name = "libx264", encoder_options = (color_range = 2, crf = 0, preset = "ultrafast")) do writer
            for (img, i) in zip(vid, ij)
                j = CartesianIndex(Tuple(i) .÷ s)
                draw!(img, CirclePointRadius(j, 5), colorant"red")
                write(writer, img)
            end
        end
    end
end

function fix_issue_1146!(df, files)
    # patch for https://github.com/JuliaData/CSV.jl/issues/1146
    if length(files) == 1
        df.csv_source .= only(files)
    end
end



# function findfirstfont()
#     for c in 'a':'z'
#         face = findfont(string(c))
#         if !isnothing(face)
#             return face
#         end
#     end
#     return nothing
# end



# function save_all_videos(results_dir, data_path, runs)
#     face = findfirstfont()
#     w, h = (480, 270)
#     img = Matrix{RGB{N0f8}}(undef, h, w)
#     open_video_out(joinpath(results_dir, "all.mp4"), img; framerate = 90, codec_name = "libx264", encoder_options = (color_range = 2, crf = 0, preset = "ultrafast")) do writer
#         for row in eachrow(runs)
#             start, stop, path, file = (row.runs_start, row.runs_stop, row.runs_path, row.file)
#             file = joinpath(data_path, path, file)
#             wh = openvideo(VideoIO.out_frame_size, file)
#             ss = (h, w) ./ reverse(wh)
#             t = stop - start
#             ijt = CSV.read(joinpath(results_dir, "$(row.row_number).csv"), DataFrame)
#             framerate = 1/first(diff(ijt.t))
#             ij = CartesianIndex.(ijt.i, ijt.j)
#             cmd = `$(ffmpeg()) -loglevel 8 -ss $start -i $file -t $t -r $framerate -vf "scale=$w:$h" -preset veryfast -f matroska -`
#             openvideo(open(cmd)) do vid
#                 for (img, i) in zip(vid, ij)
#                     j = CartesianIndex(round.(Int, Tuple(i) .* ss))
#                     draw!(img, CirclePointRadius(j, 5), colorant"red")
#                     renderstring!(img, string(row.row_number), face, 30, 30, 30, halign=:hleft, valign=:vtop, fcolor=RGB(0, 1, 0), bcolor=nothing) 
#                     write(writer, img)
#                 end
#             end
#         end
#     end
# end
# function getsz(file)  
#     openvideo(file) do vid
#         img = read(vid)
#         size(img)
#     end
# end
#
# function save_diagnostic_video(path, row_number, start, stop, fullfile, results_dir)
#     # face = findfirstfont()
#     sz_out = (270, 480)
#     h, w = sz_out
#     sz_in = getsz(fullfile)
#     scaling_factor = sz_out ./ sz_in
#     t = stop - start
#     ijt = CSV.read(joinpath(results_dir, "$row_number.csv"), DataFrame)
#     framerate = 1/2first(diff(ijt.t))
#     ij = [CartesianIndex(round.(Int, (ijt.i[i], ijt.j[i]) .* scaling_factor)) for i in 1:2:nrow(ijt)]
#     # cmd = `$(ffmpeg()) -loglevel 8 -ss $start -i $fullfile -r $framerate -vf "scale=$w:$h, drawtext=text='$row_number':fontsize=30:fontcolor=green:x=30:y=30" -preset veryfast -f matroska -`
#     cmd = `$(ffmpeg()) -ss $start -i $fullfile -r $framerate -t $t -vf "scale=$w:$h, drawtext=fontfile=arialbd.ttf:text='1'" -preset veryfast -f matroska $(joinpath(path, "$row_number.ts"))`
#     run(cmd)
#     # cmd = `$(ffmpeg()) -loglevel 8 -ss $start -i $fullfile -t $t -r $framerate -vf "scale=$w:$h" -preset veryfast -f matroska -`
#     # open_video_out(joinpath(path, "$row_number.ts"), RGB{N0f8}, sz_out; framerate = 90, encoder_options = (;color_range = 2)) do writer
#     #     io = open(cmd)
#     #     openvideo(io) do vid
#     #         for (img, i) in zip(vid, ij)
#     #             draw!(img, CirclePointRadius(i, 5), colorant"red")
#     #             # renderstring!(img, string(row_number), face, 30, 30, 30, halign=:hleft, valign=:vtop, fcolor=RGB(0, 1, 0), bcolor=nothing) 
#     #             write(writer, img)
#     #         end
#     #     end
#     #     close(io)
#     # end
# end
#
# function save_all_videos(results_dir, data_path, runs)
#     mktempdir() do path
#         p = Progress(nrow(runs); desc = "Generating all the diagnostic videos for the runs:")
#         foreach(eachrow(runs)) do row
#             save_diagnostic_video(path, row.row_number, row.runs_start, row.runs_stop, row.fullfile, results_dir)
#             next!(p)
#         end
#         finish!(p)
#         file_list = join([joinpath(path, string(row.row_number, ".ts")) for row in eachrow(runs)], '|')
#         @time run(`$(ffmpeg()) -loglevel 8 -i "concat:$file_list" -c copy $(joinpath(results_dir, "all.mp4"))`)
#     end
# end
#
#
# function save_diagnostic_video(path, row_number, start, stop, fullfile, results_dir)
#     # face = findfirstfont()
#     sz_out = (270, 480)
#     h, w = sz_out
#     sz_in = getsz(fullfile)
#     scaling_factor = sz_out ./ sz_in
#     t = stop - start
#     ijt = CSV.read(joinpath(results_dir, "$row_number.csv"), DataFrame)
#     framerate = 1/2first(diff(ijt.t))
#     ij = [CartesianIndex(round.(Int, (ijt.i[i], ijt.j[i]) .* scaling_factor)) for i in 1:2:nrow(ijt)]
#     # cmd = `$(ffmpeg()) -loglevel 8 -ss $start -i $fullfile -r $framerate -vf "scale=$w:$h, drawtext=text='$row_number':fontsize=30:fontcolor=green:x=30:y=30" -preset veryfast -f matroska -`
#     cmd = `$(ffmpeg()) -ss $start -i $fullfile -r $framerate -t $t -vf "scale=$w:$h, drawtext=fontfile=arialbd.ttf:text='1'" -preset veryfast -f matroska $(joinpath(path, "$row_number.ts"))`
#     run(cmd)
#     # cmd = `$(ffmpeg()) -loglevel 8 -ss $start -i $fullfile -t $t -r $framerate -vf "scale=$w:$h" -preset veryfast -f matroska -`
#     # open_video_out(joinpath(path, "$row_number.ts"), RGB{N0f8}, sz_out; framerate = 90, encoder_options = (;color_range = 2)) do writer
#     #     io = open(cmd)
#     #     openvideo(io) do vid
#     #         for (img, i) in zip(vid, ij)
#     #             draw!(img, CirclePointRadius(i, 5), colorant"red")
#     #             # renderstring!(img, string(row_number), face, 30, 30, 30, halign=:hleft, valign=:vtop, fcolor=RGB(0, 1, 0), bcolor=nothing) 
#     #             write(writer, img)
#     #         end
#     #     end
#     #     close(io)
#     # end
# end

