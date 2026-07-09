# The per-cell parsing machinery (mytryparse/MyTemporal/parseto!) and the defaults validation
# live in the shared ..Parsing module; this file holds what is gateway-specific — the defaults
# whitelist and the per-type row parsers and row-level checks.

# The globally overridable defaults: exactly the video-type tuning parameters — not identities
# or anchors (`calibration_id`/`file`/`extrinsic`/`matlab_file`/`extrinsic_index`/`path`), not the
# scene points (`center`/`north`), not `aspect`, not the intrinsic window (`start`/`stop`), and
# not only_scale's `scale` (a global pixels-per-unit makes no sense), which are all inherently
# per-row. The caller replaces any of these via `load_rectifications`' `defaults` kwarg (in
# Fromage: `main`'s `rectification_defaults`); a csv cell always wins over the replaced default
# (see parseto!). `yadif = missing` means "imputed from the probed video", so a caller-supplied
# yadif beats the probe on every row whose cell is blank.
const DEFAULTS = (;
    checker_size = 4.0,
    n_corners = (7, 10),
    temporal_step = 2.0,
    radial_parameters = 1,
    blur = 1.0,
    yadif = missing,
)

const DEFAULT_TYPES = (;
    checker_size = Float64,
    n_corners = NTuple{2, Int},
    temporal_step = Float64,
    radial_parameters = Int,
    blur = Float64,
    yadif = Bool,
)

resolve_defaults(overrides) = Parsing.resolve_defaults(overrides, DEFAULTS, DEFAULT_TYPES, "rectification")

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

# AprilTag rectification. `apriltags` (expected tag count) defaults to 4, `family` to "tag36h11",
# and `checker_size` here is the size of a single tag CELL (default 12) — not the black-corner-to-
# corner span (that is `cells_across(family) × checker_size`). `center`/`north` are pixels in the
# extrinsic frame, optional as elsewhere. aspect is imputed from the video (unused by the method).
function parse_apriltag!(dict, row)
    parseto!(dict, row, :calibration_id, String)
    parseto!(dict, row, :file, String)
    parseto!(dict, row, :extrinsic, MyTemporal)
    parseto!(dict, row, :apriltags, Int, 4)
    parseto!(dict, row, :family, String, "tag36h11")
    parseto!(dict, row, :checker_size, Float64, 12.0)
    parseto!(dict, row, :path, String, ".")
    parseto!(dict, row, :center, NTuple{2,Int}, missing)
    parseto!(dict, row, :north, NTuple{2,Int}, missing)
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

function parse_video!(dict, row, defaults)
    parseto!(dict, row, :calibration_id, String)
    parseto!(dict, row, :file, String)
    parseto!(dict, row, :extrinsic, MyTemporal)
    parseto!(dict, row, :start, MyTemporal, missing)
    parseto!(dict, row, :stop, MyTemporal, missing)
    parseto!(dict, row, :path, String, ".")
    parseto!(dict, row, :center, NTuple{2,Int}, missing)
    parseto!(dict, row, :north, NTuple{2,Int}, missing)
    parseto!(dict, row, :n_corners, NTuple{2,Int}, defaults.n_corners)
    parseto!(dict, row, :checker_size, Float64, defaults.checker_size)
    parseto!(dict, row, :temporal_step, Float64, defaults.temporal_step)
    parseto!(dict, row, :blur, Float64, defaults.blur)
    parseto!(dict, row, :radial_parameters, Int, defaults.radial_parameters)
    parseto!(dict, row, :aspect, Float64, missing)
    # aspect and yadif are read from the video itself (one ffprobe in read_video_metadata!) when left
    # blank; a CSV-supplied value (or a global yadif default) wins. yadif marks interlaced footage
    # (deinterlace needed). width/height are always taken from the video (the frame size used to
    # decode it) and have no CSV column.
    parseto!(dict, row, :yadif, Bool, defaults.yadif)
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

function parse_row(row, defaults = DEFAULTS)
    dict = Dict{Symbol, Any}(:issues => String[])
    # trim whitespace (as for the other string fields) and treat a now-empty cell as the default.
    type = String(strip(coalesce(get(row, :type, "video"), "video")))
    isempty(type) && (type = "video")
    dict[:type] = type
    if type == "video"
        parse_video!(dict, row, defaults)
        verify_pair(dict, :start, :stop)
    elseif type == "matlab"
        parse_matlab!(dict, row)
    elseif type == "only_scale"
        parse_only_scale!(dict, row)
    elseif type == "apriltag"
        parse_apriltag!(dict, row)
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
