# The per-cell parsing machinery (mytryparse/MyTemporal/parseto!) and the defaults validation
# live in the shared ..Parsing module; this file holds what is gateway-specific — the MyWindow
# cell type, the defaults whitelist, the row parser, and resolve_run_ids!.

# `window_size` accepts either a single side length ("31") or a (width, height) pair ("(31, 41)").
# Try the scalar first, then fall back to the tuple parser. (Extends the shared mytryparse on a
# type this module owns.)
struct MyWindow end
function mytryparse(::Type{MyWindow}, s)
    i = tryparse(Int, strip(string(s)))
    isnothing(i) || return i
    return mytryparse(NTuple{2, Int}, s)
end

# The globally overridable defaults: exactly the tracking tuning parameters — not identities
# (`run_id`/`calibration_id`/`file`/`path`) and not the temporal window (`start`/`stop`/
# `start_location`), which are inherently per-row. The caller replaces any of these via
# `load_runs`' `defaults` kwarg (in Fromage: `main`'s `tracking_defaults`); a csv cell always
# wins over the replaced default (see parseto!). `fps = missing` means "imputed from the probed
# video", so a caller-supplied fps beats the probe on every row whose cell is blank.
const DEFAULTS = (;
    target_width = 25.0,
    window_size = missing,
    darker_target = true,
    fps = missing,
    initial_search_factor = 4.0,
    white_point = 1.0,
    scale = 1.0,
)

const DEFAULT_TYPES = (;
    target_width = Float64,
    window_size = Union{Int, NTuple{2, Int}},
    darker_target = Bool,
    fps = Float64,
    initial_search_factor = Float64,
    white_point = Float64,
    scale = Float64,
)

resolve_defaults(overrides) = Parsing.resolve_defaults(overrides, DEFAULTS, DEFAULT_TYPES, "tracking")

# Every column maps to one `track` keyword (plus `run_id`/`path` for identity & path resolution).
# The hardcoded defaults (see DEFAULTS) mirror `PawsomeTracker.track`'s own so a blank cell behaves
# exactly as omitting the argument would. `stop`/`fps` are left missing here and imputed from the
# probed video (duration / framerate); `window_size`/`start_location` stay missing and are simply
# omitted from the `track` call.
function parse_run!(dict, row, defaults)
    parseto!(dict, row, :run_id, String, missing)               # all-or-nothing: blank only allowed when every row is blank (then imputed from the row number); see resolve_run_ids!
    parseto!(dict, row, :calibration_id, String)                # required: Fromage joins runs to rectifications on it
    parseto!(dict, row, :file, String)
    parseto!(dict, row, :path, String, ".")
    parseto!(dict, row, :start, MyTemporal, 0.0)
    parseto!(dict, row, :stop, MyTemporal, missing)              # imputed from video duration
    parseto!(dict, row, :target_width, Float64, defaults.target_width)
    parseto!(dict, row, :start_location, NTuple{2, Int}, missing)
    parseto!(dict, row, :window_size, MyWindow, defaults.window_size)
    parseto!(dict, row, :darker_target, Bool, defaults.darker_target)
    parseto!(dict, row, :fps, Float64, defaults.fps)             # imputed from video framerate when missing
    parseto!(dict, row, :initial_search_factor, Float64, defaults.initial_search_factor)
    parseto!(dict, row, :white_point, Float64, defaults.white_point)
    parseto!(dict, row, :scale, Float64, defaults.scale)
end

function parse_row(row, defaults = DEFAULTS)
    dict = Dict{Symbol, Any}(:issues => String[])
    parse_run!(dict, row, defaults)
    for col in COLUMNS
        haskey(dict, col) || (dict[col] = missing)
    end
    return dict
end

# run_id is all-or-nothing: either every row names its run (enabling multi-segment runs), or no
# row does (column absent, or present with every cell blank) and each row becomes its own
# single-segment run, identified by its 1-based row number. A mixed file is rejected — under
# partial numbering a blank row's auto-generated id could silently merge with an explicit one
# (e.g. "3") into a bogus multi-segment run, so there is no safe way to honor it. In the mixed
# case the blanks stay missing: Run construction only happens on the issue-free path, and
# verify_run_consistency! skips missing-id groups.
function resolve_run_ids!(df)
    if all(ismissing, df.run_id)
        df.run_id = string.(1:nrow(df))
    elseif any(ismissing, df.run_id)
        rows = findall(ismissing, df.run_id)
        push!.(df.issues[rows], "run_id is missing (either every row has a run_id or none does)")
    end
    return df
end
