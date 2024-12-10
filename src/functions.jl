# function read_xlsx(file)
#     f = XLSX.readxlsx(file)
#     sheet = first(XLSX.sheetnames(f))
#     io = IOBuffer()
#     CSV.write(io, DataFrame(XLSX.gettable(f[sheet])))
#     CSV.read(take!(io), DataFrame)
# end


function get_recording_datetime(file)
    txts = strip.(split(read(`$exiftool -T -AllDates -n $file`, String), '\t'))
    dt = DateTime(now())
    for txt in txts
        if length(txt) > 18
            _dt = DateTime(txt[1:19], DateFormat("yyyy:mm:dd HH:MM:SS"))
            dt = min(_dt, dt)
        end
    end
    return dt
end

function get_all_csv(dir, type)
    files = String[]
    r = Regex("^.*$type.*\\.csv\$")
    for (root, _, _files) in walkdir(dir), file in _files
        if occursin(r, file)
            push!(files, joinpath(root, file))
        end
    end
    return files
end

# function replace_with_uuid!(tbl)
#     if "start_xy" ∈ names(tbl)
#         todo = subset(tbl, :start_xy => ByRow(x -> isa(x, Int)); skipmissing = true, view = true)
#         transform!(todo, :start_xy => ByRow(i -> tbl.id[i]), renamecols = false)
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

tosecond(t::T) where {T <: TimePeriod} = t / convert(T, Dates.Second(1))
tosecond(t::TimeType) = tosecond(t - Time(0))
tosecond(sec::Real) = sec
tosecond(str::AbstractString) = ':' ∈ str ? tosecond(Time(str)) : parse(Float64, str)

function to_tuple(x::AbstractString)
    m = match(r"^\((\d+),\s*(\d+)\)$", x)
    Tuple{Int, Int}(parse.(Int, m.captures))
end
to_tuple(x::Tuple{Int, Int}) = x
to_tuple(::Missing) = missing

function save_vid(results_dir, name, file, t, xy)
    openvideo(file) do vid
        aspect = VideoIO.aspect_ratio(vid)
        img = read(vid)
        sz = size(img)
        sz2 = round.(Int, (sz[1], sz[2]*aspect) ./ 4)
        frame = imresize(img, sz2)
        t₀ = gettime(vid)
        t .+= t₀
        seek(vid, t[1])
        open_video_out(joinpath(results_dir, "$name.mp4"), frame, framerate = 60, codec_name = "libx264", encoder_options = (color_range = 2, crf = 0, preset = "ultrafast")) do writer
            for (img, (x, y)) in zip(vid, xy)
                draw!(img, CirclePointRadius(x, y, 5), colorant"red")
                imresize!(frame, img)
                write(writer, frame)
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
