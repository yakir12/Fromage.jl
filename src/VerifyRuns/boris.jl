# The runs file comes in two shapes, and this file turns either into the same thing: one record per
# segment, each a row `parse_row` can read, the issues already found about it, and the cells that are
# not Fromage's to parse (where it came from, and the user's metadata). Everything after that —
# parsing, defaults, imputation, both tiers of checks, the one report — is the runs.csv pipeline,
# unchanged (DECISIONS, "A BORIS export is adapted in memory, not translated to a runs.csv", #409).
#
# The shape is a type, chosen from the header, as rectification builders are chosen by type:
#
# - `RunsCsv()`: the identity. A `runs.csv` row IS a segment, and cites itself as `row i`.
# - `BorisExport(behavior)`: a BORIS "Tabular events" export, one row per START or STOP of a coded
#   behaviour. Each START/STOP pair of `behavior` becomes a segment — or several, when the pair
#   crosses from one of the observation's videos into the next.

struct RunsCsv end

struct BorisExport
    behavior::String
end

# Every column BORIS writes whatever the project. An export also carries the project's independent
# variables and modifiers (`Modifier #1`, …), which vary, so a file is recognised by these six
# alone. Matched on the exact spelling BORIS writes, so a `runs.csv` can never be mistaken for one.
const BORIS_COLUMNS = Symbol.(
    (
        "Observation id", "Observation date", "Description", "Observation duration",
        "Observation type", "Source", "Time offset (s)", "Media duration (s)", "FPS", "Subject",
        "Behavior", "Behavioral category", "Behavior type", "Time", "Media file name",
        "Image index", "Image file path", "Comment",
    )
)
const BORIS_SIGNATURE = Symbol.(
    ("Observation id", "Behavior type", "Time", "Media file name", "Source", "Media duration (s)")
)

runs_format(names, behavior) = BORIS_SIGNATURE ⊆ names ? BorisExport(behavior) : RunsCsv()

# What `read_rows`' header screening counts as known: a BORIS export's own columns are not metadata
# that might be a misspelt Fromage column (its `Comment` is one edit from `comment`).
known_columns(::RunsCsv) = COLUMNS
known_columns(::BorisExport) = (COLUMNS..., BORIS_COLUMNS...)

# BORIS writes `FPS` to three decimals, so a rate it read exactly is within 0.0005 of the probe's.
const BORIS_FPS_TOLERANCE = 0.001

# What a segment record carries beyond its Fromage cells. `csv_rows` is where it came from in the
# user's file (data rows counted from 1, as the report has always numbered them). `boris_fps` is the
# rate BORIS played the segment's video at, which verifications! compares with the probed one; a
# runs.csv has none, so `missing` there passes that check by.
runs_csv_extra(i) = Dict{Symbol, Any}(:csv_rows => [i], :boris_fps => missing)

# A runs.csv row is its own segment, with nothing found about it yet.
segment_records(::RunsCsv, _, rows) = [(; cells = r, issues = String[], extra = runs_csv_extra(i)) for (i, r) in enumerate(rows)]

# The report's name for a record's rows in the user's own file. A runs.csv row's label is exactly
# what it always was.
row_label(rows) = isempty(rows) ? "every row" :
    length(rows) == 1 ? "row $(only(rows))" : "rows $(join(rows, " and "))"

# ---- the observation's clock ------------------------------------------------------------------

# Player #1's videos, played back to back, are the observation's timeline. `ends` is where each
# video ends on it, so video `k` covers `[ends[k-1], ends[k])`.
struct BorisClock
    files::Vector{String}       # basenames: the coder's absolute paths name another machine
    durations::Vector{Float64}
    ends::Vector{Float64}
    fps::Vector{Float64}
end

cell(cells, name) = get(cells, Symbol(name), missing)

# A `;`-separated list of positive, finite numbers, one per video — or `nothing`.
function number_list(s)
    xs = map(x -> tryparse(Float64, strip(x)), split(s, ';'))
    any(x -> isnothing(x) || !isfinite(x) || x ≤ 0, xs) && return nothing
    return Float64[x for x in xs]
end

# `C:\videos\a.mp4` as well as `E:/videos/a.mp4`: the export was written on whatever machine did
# the coding, so its separator is not this machine's, and `basename` alone would not do.
file_name(path) = String(last(split(path, ('/', '\\'))))

# Parse the clock out of one row's cells, pushing what is wrong with them onto `issues`. Every row
# repeats these cells, so each row is read on its own; a pair's two rows agree in any real export.
function boris_clock!(issues, cells)
    type = cell(cells, "Observation type")
    isequal(type, "Media file(s)") ||
        push!(issues, "Observation type must be Media file(s) — live observations and image folders have no video to track")
    source = cell(cells, "Source")
    m = ismissing(source) ? nothing : match(r"^player #1:(.*)$", source)
    if isnothing(m)
        push!(issues, "wrong Source format")
        return nothing
    end
    players = split(something(m.captures[1]), '|')
    if length(players) > 1
        push!(issues, "Source must name a single player")
        return nothing
    end
    files = file_name.(split(only(players), ';'))
    durations = passmissing(number_list)(cell(cells, "Media duration (s)"))
    fps = passmissing(number_list)(cell(cells, "FPS"))
    ok = true
    if ismissing(durations) || isnothing(durations)
        push!(issues, "wrong Media duration (s) format")
        ok = false
    elseif length(durations) != length(files)
        push!(issues, "Media duration (s) must list one duration per video in Source")
        ok = false
    end
    if ismissing(fps) || isnothing(fps)
        push!(issues, "wrong FPS format")
        ok = false
    elseif length(fps) != length(files)
        push!(issues, "FPS must list one rate per video in Source")
        ok = false
    end
    ok || return nothing
    return BorisClock(files, durations, cumsum(durations), fps)
end

# The row's observation time: BORIS's `Time` less its `Time offset (s)`, so 0 is the start of the
# first video. Outside the videos it is an issue — which is also how an observation coded with the
# media creation date as its offset shows up, since its times are wall-clock and nothing else in
# the export says so.
function observation_time!(issues, cells, clock)
    time = passmissing(x -> tryparse(Float64, x))(cell(cells, "Time"))
    offset = passmissing(x -> tryparse(Float64, x))(cell(cells, "Time offset (s)"))
    bad = false
    (ismissing(time) || isnothing(time) || !isfinite(time)) && (push!(issues, "wrong Time format"); bad = true)
    (ismissing(offset) || isnothing(offset) || !isfinite(offset)) && (push!(issues, "wrong Time offset (s) format"); bad = true)
    (bad || isnothing(clock)) && return nothing
    t = time - offset
    if !(0 ≤ t ≤ last(clock.ends))
        push!(issues, "Time must lie within the observation's videos: between Time offset (s) and Time offset (s) plus their total Media duration (s)")
        return nothing
    end
    return t
end

# Which video an observation time falls in, and the file time there. A START is a beginning, so it
# takes BORIS's own rule: video k holds [start, end), and the very end of the last video belongs to
# it. A STOP is an end, so a STOP exactly on a boundary ends the earlier video rather than opening
# the next one at 0 — which would be a segment with nothing in it.
abstract type Edge end
struct Opening <: Edge end
struct Closing <: Edge end

video_at(clock, t, ::Opening) = min(searchsortedlast(clock.ends, t) + 1, length(clock.ends))
video_at(clock, t, ::Closing) = max(searchsortedfirst(clock.ends, t), 1)

function locate(clock, t, edge)
    k = video_at(clock, t, edge)
    return k, t - (k == 1 ? 0.0 : clock.ends[k - 1])
end

# ---- pairing ----------------------------------------------------------------------------------

# One START and its STOP, or a lone START or STOP that found no partner (`nothing` on that side).
struct CodedPair
    start::Union{Nothing, Int}
    stop::Union{Nothing, Int}
    issue::Union{Nothing, String}
end

csv_rows(p::CodedPair) = Int[i for i in (p.start, p.stop) if !isnothing(i)]

# Within each Subject, the behaviour's rows must alternate START, STOP in file order. A START
# followed by another START has no STOP; a STOP with nothing open has no START. Both are reported on
# a record of their own, so the pairs around them still go through. `rows` are row indices of the
# chosen behaviour, in file order.
function pair_rows(rows, all_cells)
    open = Dict{String, Int}()     # Subject → its unmatched START
    pairs = CodedPair[]
    for i in rows
        subject = coalesce(cell(all_cells[i], "Subject"), "")
        type = cell(all_cells[i], "Behavior type")
        if isequal(type, "START")
            j = pop!(open, subject, nothing)
            isnothing(j) || push!(pairs, CodedPair(j, nothing, "Behavior type must alternate START and STOP within a Subject — this START has no STOP"))
            open[subject] = i
        elseif isequal(type, "STOP")
            j = pop!(open, subject, nothing)
            push!(pairs, isnothing(j) ? CodedPair(nothing, i, "Behavior type must alternate START and STOP within a Subject — this STOP has no START") : CodedPair(j, i, nothing))
        else
            push!(pairs, CodedPair(i, nothing, "Behavior type must be START or STOP: a POINT event marks no stretch of video to track"))
        end
    end
    for j in values(open)
        push!(pairs, CodedPair(j, nothing, "Behavior type must alternate START and STOP within a Subject — this START has no STOP"))
    end
    return sort!(pairs; by = p -> first(csv_rows(p)))
end

# ---- one pair → its segments ------------------------------------------------------------------

# A user-defined cell of a pair: the same on both rows once, or START's then STOP's.
joined(a, b) = isequal(a, b) ? a : string(coalesce(a, ""), " | ", coalesce(b, ""))

# The Fromage columns the user wrote into the export, which the pair's rows must agree on. `file`,
# `start` and `stop` are the adapter's to fill, so a column of that name is not read.
const ADAPTER_COLUMNS = (:file, :start, :stop)

function segment_records(format::BorisExport, names, rows)
    all_cells = [Dict{Symbol, Union{Missing, String}}(n => passmissing(String)(Tables.getcolumn(r, n)) for n in names) for r in rows]
    fromage = [n for n in names if n in COLUMNS && n ∉ ADAPTER_COLUMNS]
    user = [n for n in names if n ∉ COLUMNS && n ∉ BORIS_COLUMNS]
    chosen = [
        i for (i, c) in enumerate(all_cells) if isequal(cell(c, "Behavior"), format.behavior)
    ]
    if !any(i -> cell(all_cells[i], "Behavior type") in ("START", "STOP"), chosen)
        issue = "Behavior must be $(format.behavior) on at least one START or STOP row (boris_behavior selects which behaviour is tracked)"
        return [(; cells = nothing, issues = [issue], extra = Dict{Symbol, Any}(:csv_rows => Int[], :boris_fps => missing))]
    end
    return reduce(vcat, [pair_segments(p, all_cells, fromage, user) for p in pair_rows(chosen, all_cells)])
end

function pair_segments(p::CodedPair, all_cells, fromage, user)
    issues = isnothing(p.issue) ? String[] : [p.issue]
    rows = csv_rows(p)
    first_cells, last_cells = all_cells[first(rows)], all_cells[last(rows)]

    any(i -> !filled(all_cells[i], :run_id), rows) &&
        push!(issues, "run_id must be filled on every row of the tracked behaviour in a BORIS export")
    cells = Dict{Symbol, Any}()
    for c in fromage
        a, b = first_cells[c], last_cells[c]
        isequal(a, b) || push!(issues, "$c must be the same on a pair's START and STOP rows")
        cells[c] = a
    end
    metadata = Dict{Symbol, Any}(
        :csv_rows => rows,
        :subject => joined(cell(first_cells, "Subject"), cell(last_cells, "Subject")),
        :behavior => cell(first_cells, "Behavior"),
        :observation_id => joined(cell(first_cells, "Observation id"), cell(last_cells, "Observation id")),
        :comment => joined(cell(first_cells, "Comment"), cell(last_cells, "Comment")),
    )
    for c in user
        metadata[c] = joined(first_cells[c], last_cells[c])
    end

    # Each row's own clock and time: both rows' problems are reported, not just the first's.
    clocks = [boris_clock!(issues, all_cells[i]) for i in rows]
    times = [observation_time!(issues, all_cells[i], clock) for (i, clock) in zip(rows, clocks)]
    unique!(issues)                 # the two rows of a pair share their faults
    clock = first(clocks)
    windows = if isnothing(clock) || any(isnothing, times)
        [UNPLACED]
    else
        boris_windows!(issues, clock, p, times)
    end
    return [
        (; cells = merge(cells, Dict{Symbol, Any}(:file => w.file, :start => w.start, :stop => w.stop)), issues = copy(issues), extra = merge(metadata, Dict{Symbol, Any}(:file => placed_file(w), :boris_fps => w.fps)))
            for w in windows
    ]
end

# The window of a pair whose video could not be found: the issues above already say why. Its `file`
# cell is filled for the parser, so that it does not add `file is missing` about a column the
# export does not have, and the record's `extra` puts `missing` back over it, which every later
# stage skips.
const UNPLACED = (file = "(not placed)", start = missing, stop = missing, fps = missing)
placed_file(w) = w === UNPLACED ? missing : w.file

# The file windows a pair covers. A pair inside one video is one window; one that crosses into later
# videos is split into one per video it touches — START to the end of its video, every video between
# whole, and the last from its start to STOP — so that no segment spans two files. A lone START or
# STOP is one window with the other end left to the defaults (start 0, stop the video's end).
function boris_windows!(issues, clock, p::CodedPair, times)
    # `times` follows `csv_rows(p)`: the START's, then the STOP's, whichever of the two there are
    k0, a = isnothing(p.start) ? (nothing, missing) : locate(clock, first(times), Opening())
    k1, b = isnothing(p.stop) ? (nothing, missing) : locate(clock, last(times), Closing())
    window(k, start, stop) = (file = clock.files[k], start, stop, fps = clock.fps[k])
    isnothing(k0) && return [window(k1, missing, b)]
    isnothing(k1) && return [window(k0, a, missing)]
    if k1 < k0
        push!(issues, "Time must not be earlier on a STOP row than on its START row")
        return [window(k0, a, missing)]
    end
    return [window(k, k == k0 ? a : 0.0, k == k1 ? b : clock.durations[k]) for k in k0:k1]
end
