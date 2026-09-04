# The per-cell parsing machinery (mytryparse/MyTemporal/parseto!) and the defaults validation
# live in the shared ..Parsing module; this file holds what is gateway-specific — the defaults
# whitelist and the per-type row parsers and row-level checks.

# The globally overridable defaults: every tuning parameter any type reads. Everything else —
# identities and anchors, the scene points, `aspect`, the intrinsic window, uniform's
# `pixel_width` — is inherently per-row. The caller replaces any of these via `load_rectifications`' `defaults`
# kwarg (in Fromage: `main`'s `rectification_defaults`), and a csv cell always wins over the
# replaced default (see parseto!). `yadif = missing` means "imputed from the probed video", so a
# caller-supplied yadif beats the probe on every row whose cell is blank.
#
# The apriltag three (`apriltags`/`family`/`tag_cell_width`) used to be hardcoded in
# `parse_apriltag!` and were therefore unreachable from `main` (#140). They live here now, on the
# same footing as the checkerboard ones. `tag_cell_width` is a column of its own precisely so it
# can: it and `checker_width` are different physical quantities (a tag cell vs a checkerboard square)
# that shared one column until v0.1.58, which left a single default unable to serve both — a
# global `checker_width` silently did nothing to apriltag rows.
const DEFAULTS = (;
    checker_width = 4.0,
    n_corners = (7, 10),
    temporal_step = 2.0,
    radial_parameters = 1,
    blur = 1.0,
    yadif = missing,
    apriltags = 4,
    family = "tag36h11",
    tag_cell_width = 12.0,
)

const DEFAULT_TYPES = (;
    checker_width = Float64,
    n_corners = NTuple{2, Int},
    temporal_step = Float64,
    radial_parameters = Int,
    blur = Float64,
    yadif = Bool,
    apriltags = Int,
    family = String,
    tag_cell_width = Float64,
)

resolve_defaults(overrides) = Parsing.resolve_defaults(overrides, DEFAULTS, DEFAULT_TYPES, "rectification")

function parse_uniform!(dict, row)
    parseto!(dict, row, :calibration_id, String)
    parseto!(dict, row, :file, String)
    parseto!(dict, row, :extrinsic, MyTemporal)
    parseto!(dict, row, :pixel_width, Float64)
    parseto!(dict, row, :path, String, ".")
    parseto!(dict, row, :center, NTuple{2,Int}, missing)
    parseto!(dict, row, :north, NTuple{2,Int}, missing)
    # aspect is read from the source video (one ffprobe in read_video_metadata!) when left blank; a
    # CSV-supplied value wins. width/height are always taken from the video and have no CSV column.
    parseto!(dict, row, :aspect, Float64, missing)
end

# AprilTag rectification. `apriltags` is the expected tag count and `tag_cell_width` the size of a
# single tag CELL — not the black-corner-to-corner span, which is `cells_across(family) ×
# tag_cell_width`. `center`/`north` are pixels in the extrinsic frame, optional as elsewhere.
# aspect is imputed from the video (unused by the method). All three tunables take their default
# from `defaults`, so `rectification_defaults` reaches them like any other (#140).
function parse_apriltag!(dict, row, defaults)
    parseto!(dict, row, :calibration_id, String)
    parseto!(dict, row, :file, String)
    parseto!(dict, row, :extrinsic, MyTemporal)
    parseto!(dict, row, :apriltags, Int, defaults.apriltags)
    parseto!(dict, row, :family, String, defaults.family)
    parseto!(dict, row, :tag_cell_width, Float64, defaults.tag_cell_width)
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

function parse_checkerboard!(dict, row, defaults)
    parseto!(dict, row, :calibration_id, String)
    parseto!(dict, row, :file, String)
    parseto!(dict, row, :extrinsic, MyTemporal)
    parseto!(dict, row, :intrinsic_start, MyTemporal, missing)
    parseto!(dict, row, :intrinsic_stop, MyTemporal, missing)
    parseto!(dict, row, :path, String, ".")
    parseto!(dict, row, :center, NTuple{2,Int}, missing)
    parseto!(dict, row, :north, NTuple{2,Int}, missing)
    parseto!(dict, row, :n_corners, NTuple{2,Int}, defaults.n_corners)
    parseto!(dict, row, :checker_width, Float64, defaults.checker_width)
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

# The two calibs bounds are all-or-nothing. Asked of the CSV cells, not of the parsed values: a cell
# that was filled in but malformed is *present*, and the parser has already said so — comparing the
# parsed types instead reported a second, contradictory issue for one typo, and nulled the good
# bound along with it.
function verify_pair(dict, row, k1, k2)
    filled(row, k1) == filled(row, k2) && return
    dict[k1] = dict[k2] = missing
    push!(dict[:issues], "$k1 and $k2 should be either both present or both missing")
end

function verify_center2north(dict)
    if ismissing(dict[:center]) && !ismissing(dict[:north])
        dict[:north] = missing
        push!(dict[:issues], "supplying north without center doesn't make sense")
    end
end

# A filled cell in a column the row's type never reads is flagged: it would otherwise be silently
# ignored, and it usually means the `type` itself is wrong (e.g. a `pixel_width` on a checkerboard
# row). The type-specific parser has already put every column it consumed into `dict`, so anything
# non-blank
# left in the row is irrelevant to this type. Blank cells are fine — mixed-type CSVs share one
# header, so irrelevant *columns* must be allowed to exist, just not filled. Must run before the
# COLUMNS back-fill, which adds every column to `dict`.
#
# `type` is exempt because it selects the parser, and so is consumed by definition; `comment` is
# exempt because it is free text that no parser reads by design (#16).
#
# One (type, column) pair gets a targeted hint instead of the generic message. The checkerboard
# square size and the tag cell width shared a column until v0.1.58; a user who has migrated that
# column to its new name `checker_width` but not yet noticed that apriltag rows went somewhere else
# entirely is not making a type error — they are holding a value that moved. "not used by type
# apriltag" would send them looking for the wrong thing. (A file still naming the old
# `checker_size` never reaches here: `read_rows` rejects it, with RENAMED_COLUMNS' hint.)
const RENAMED = Dict(("apriltag", :checker_width) => :tag_cell_width)

# Retired `type` VALUES, and what each became. The sibling of RENAMED_COLUMNS one level down: that
# table is consulted by `read_rows` for a retired column NAME, before any row is parsed, and cannot
# see values. Both renames landed in v0.2.23 — `video` because every type here is anchored to a
# source video and so the name distinguished nothing, `only_scale` because its `scale` column became
# `pixel_width` and left the type pointing at a word no longer in the file.
#
# Without this a migrating file's most common value produces the file's least useful message: bare
# "wrong type", which neither echoes what was written nor says where it went.
const RENAMED_TYPES = Dict(
    "video" => "checkerboard",
    "only_scale" => "uniform",
)

function verify_irrelevant(dict, row)
    ismissing(dict[:type]) && return          # wrong type: already reported, no field list to check
    for k in Tables.columnnames(row)
        (haskey(dict, k) || k == :type || k == :comment) && continue
        v = row[k]
        (ismissing(v) || (v isa AbstractString && isempty(strip(v)))) && continue
        renamed = get(RENAMED, (dict[:type], k), nothing)
        push!(dict[:issues], isnothing(renamed) ?
            "$k is not used by type $(dict[:type])" :
            "$k is not used by type $(dict[:type]) (it was renamed to $renamed)")
    end
end

function parse_row(row, defaults = DEFAULTS)
    dict = Dict{Symbol, Any}(:issues => String[])
    # trim whitespace (as for the other string fields); a now-empty cell takes the default
    type = String(strip(coalesce(get(row, :type, "checkerboard"), "checkerboard")))
    isempty(type) && (type = "checkerboard")
    dict[:type] = type
    if type == "checkerboard"
        parse_checkerboard!(dict, row, defaults)
        verify_pair(dict, row, :intrinsic_start, :intrinsic_stop)
    elseif type == "matlab"
        parse_matlab!(dict, row)
    elseif type == "uniform"
        parse_uniform!(dict, row)
    elseif type == "apriltag"
        parse_apriltag!(dict, row, defaults)
    else
        dict[:type] = missing
        renamed = get(RENAMED_TYPES, type, nothing)
        push!(dict[:issues], isnothing(renamed) ?
            "wrong type" :
            "wrong type ($type was renamed to $renamed)")
    end
    verify_irrelevant(dict, row)
    backfill!(dict, COLUMNS)
    verify_center2north(dict)
    return dict
end
