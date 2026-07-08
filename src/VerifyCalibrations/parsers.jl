# Local parse helper mirroring Base.tryparse semantics (returns the parsed value or
# `nothing` on failure). Defining our own avoids type piracy on Base.tryparse for
# types we don't own (String, NTuple). The generic fallback delegates to Base for
# the standard types (Int, Float64, ...) used elsewhere in the parsers.
mytryparse(::Type{T}, x) where {T} = tryparse(T, x)

function mytryparse(::Type{NTuple{2, Int}}, s)
    m = match(r"^\s*[\(\[]?\s*(\d+)\s*,\s*(\d+)\s*[\)\]]?\s*$", s)
    isnothing(m) && return nothing
    a = tryparse(Int, m.captures[1])      # tryparse (not parse): a >Int64 value overflows ->
    b = tryparse(Int, m.captures[2])      # nothing -> "wrong format" issue, not an uncaught throw
    (isnothing(a) || isnothing(b)) && return nothing
    return (a, b)
end

tosecond(x::T) where {T <: TimePeriod} = Float64(x/convert(T, Second(1)))
tosecond(x::Time) = tosecond(x - Time(0))

struct MyTemporal end
function mytryparse(::Type{MyTemporal}, x)
    seconds = tryparse(Float64, x)
    isnothing(seconds) || return seconds
    time = tryparse(Time, x)
    isnothing(time) || return tosecond(time)
    return nothing
end

# Trim surrounding whitespace from hand-edited CSV cells: a stray space must not turn "video " into a
# wrong type, " file.mp4" into a missing file, or "id " vs "id" into a missed duplicate. (The numeric
# and tuple/time parsers already tolerate surrounding whitespace.)
# `String(...)` (not just `strip`) because strip returns a SubString, and the struct fields — notably
# Video's parametric auto-constructor — are typed `::String` and won't accept a SubString.
mytryparse(::Type{String}, x) = String(strip(string(x)))

function set!(dict, y, k, _)
    dict[k] = y
end

function set!(dict, ::Nothing, k, msg)
    dict[k] = missing
    push!(dict[:issues], msg)
end

function parseto!(dict, row, k, ::Type{T}, default = nothing) where T
    raw = haskey(row, k) ? row[k] : missing
    # A present-but-blank cell (whitespace only) is treated exactly like an absent one: a required
    # field then reports "is missing" instead of silently becoming an empty string, and an optional
    # field falls back to its default.
    if !ismissing(raw) && !(raw isa AbstractString && isempty(strip(raw)))
        y = mytryparse(T, raw)
        set!(dict, y, k, "wrong $k format")
    else
        set!(dict, default, k, "$k is missing")
    end
end


function parse_only_scale!(dict, row)
    parseto!(dict, row, :calibration_id, String)
    parseto!(dict, row, :file, String)
    parseto!(dict, row, :extrinsic, MyTemporal)
    parseto!(dict, row, :scale, Float64)
    parseto!(dict, row, :path, String, ".")
    parseto!(dict, row, :center, NTuple{2,Int}, missing)
    parseto!(dict, row, :north, NTuple{2,Int}, missing)
    # aspect is read from the source video (one ffprobe in read_video_metadata!) when left blank; a
    # CSV-supplied value wins. width/height are always taken from the video and have no CSV column.
    parseto!(dict, row, :aspect, Float64, missing)
end

function parse_matlab!(dict, row)
    parseto!(dict, row, :calibration_id, String)
    parseto!(dict, row, :file, String)
    parseto!(dict, row, :matlab_file, String)
    parseto!(dict, row, :extrinsic, MyTemporal)
    parseto!(dict, row, :extrinsic_index, Int)
    parseto!(dict, row, :path, String, ".")
    parseto!(dict, row, :center, NTuple{2,Int}, missing)
    parseto!(dict, row, :north, NTuple{2,Int}, missing)
    # aspect is read from the source video (one ffprobe in read_video_metadata!) when left blank; a
    # CSV-supplied value wins. width/height are always taken from the video and have no CSV column.
    parseto!(dict, row, :aspect, Float64, missing)
end

function parse_video!(dict, row)
    parseto!(dict, row, :calibration_id, String)
    parseto!(dict, row, :file, String)
    parseto!(dict, row, :extrinsic, MyTemporal)
    parseto!(dict, row, :start, MyTemporal, missing)
    parseto!(dict, row, :stop, MyTemporal, missing)
    parseto!(dict, row, :path, String, ".")
    parseto!(dict, row, :center, NTuple{2,Int}, missing)
    parseto!(dict, row, :north, NTuple{2,Int}, missing)
    parseto!(dict, row, :n_corners, NTuple{2,Int}, (7, 10))
    parseto!(dict, row, :checker_size, Float64, 4.0)
    parseto!(dict, row, :temporal_step, Float64, 2.0)
    parseto!(dict, row, :blur, Float64, 1.0)
    parseto!(dict, row, :radial_parameters, Int, 1)
    parseto!(dict, row, :aspect, Float64, missing)
    # aspect and yadif are read from the video itself (one ffprobe in read_video_metadata!) when left
    # blank; a CSV-supplied value wins. yadif marks interlaced footage (deinterlace needed). width/height
    # are always taken from the video (the frame size used to decode it) and have no CSV column.
    parseto!(dict, row, :yadif, Bool, missing)
end

function verify_pair(dict, k1, k2)
    if typeof(dict[k1]) != typeof(dict[k2])
        dict[k1] = dict[k2] = missing
        push!(dict[:issues], "$k1 and $k2 should be either both present or both missing")
    end
end

function verify_center2north(dict)
    if ismissing(dict[:center]) && !ismissing(dict[:north])
        dict[:north] = missing
        push!(dict[:issues], "supplying north without center doesn't make sense")
    end
end

# A filled cell in a column the row's type never reads would otherwise be silently ignored — and
# usually means the `type` itself is wrong (e.g. a `scale` on a video row). The type-specific
# parser has already put every column it consumed into `dict`, so anything non-blank left in the
# row is irrelevant to this type. Blank cells are fine: mixed-type CSVs share one header, so
# irrelevant *columns* must be allowed to exist, just not filled. Must run before the COLUMNS
# back-fill (which adds every column to `dict`).
function verify_irrelevant(dict, row)
    ismissing(dict[:type]) && return          # wrong type: already reported, no field list to check
    for k in Tables.columnnames(row)
        (haskey(dict, k) || k == :type) && continue
        v = row[k]
        (ismissing(v) || (v isa AbstractString && isempty(strip(v)))) && continue
        push!(dict[:issues], "$k is not used by type $(dict[:type])")
    end
end

function parse_row(row)
    dict = Dict{Symbol, Any}(:issues => String[])
    # trim whitespace (as for the other string fields) and treat a now-empty cell as the default.
    type = String(strip(coalesce(get(row, :type, "video"), "video")))
    isempty(type) && (type = "video")
    dict[:type] = type
    if type == "video"
        parse_video!(dict, row)
        verify_pair(dict, :start, :stop)
    elseif type == "matlab"
        parse_matlab!(dict, row)
    elseif type == "only_scale"
        parse_only_scale!(dict, row)
    else
        dict[:type] = missing
        push!(dict[:issues], "wrong type")
    end
    verify_irrelevant(dict, row)
    for col in COLUMNS
        if !haskey(dict, col)
            dict[col] = missing
        end
    end
    verify_center2north(dict)
    return dict
end
