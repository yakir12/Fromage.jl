module VerifyRectifications

using CSV: CSV
using ..Rectifications: get_corners, _vf
import ..Rectifications: Rectification
using Chain: Chain, @chain
using DataFramesMeta: DataFramesMeta, @groupby, @rtransform!, @transform!, AbstractDataFrame,
    ByRow, Cols, DataFrame, Not, allowmissing!, completecases, dropmissing, groupby,
    nonunique, nrow, passmissing, select, select!, subset
using ..Parsing: Parsing, MyTemporal, parseto!
using FFMPEG: ffprobe
using MAT: MAT, matread
using OhMyThreads: OhMyThreads, tmap
using PrecompileTools: @setup_workload, @compile_workload
using ProgressMeter: ProgressMeter, @showprogress
using Tables: Tables

export load_rectifications

const COLUMNS = (:comment, :calibration_id, :path, :file, :matlab_file, :start, :stop, :extrinsic, :checker_size, :center, :north, :n_corners, :scale, :type, :temporal_step, :radial_parameters, :blur, :extrinsic_index, :aspect, :yadif)

include("types.jl")
include("parsers.jl")
include("verifications.jl")

function load_rectifications(file; strict = true, defaults = (;))
    data_path = dirname(file)
    load_rectifications(data_path, file; strict, defaults)
end

# `defaults` globally replaces the hardcoded fallbacks of the whitelisted rectification parameters
# (see DEFAULTS in parsers.jl); the hierarchy is csv cell → `defaults` → hardcoded/probed value.
function load_rectifications(data_path, file; strict = true, defaults = (;))
    defaults = resolve_defaults(defaults)   # fail fast on unknown keys / unconvertible values
    # verify csv file exists
    if !isfile(file)
        error("calibration `.csv` file missing")
    end
    csvrows = CSV.Rows(file)

    # verify csv file has rows in it
    if isempty(Tables.rows(csvrows))
        error("csv file is empty")
    end

    # verify csv all the columns are expected
    sch = Tables.schema(csvrows)
    unrecognized = setdiff(sch.names, COLUMNS)
    if !isempty(unrecognized)
        error("unrecognized column/s in calibration file: $unrecognized")
    end

    # parse rows to RectificationMethods or error messages
    cs = @showprogress desc = "Parsing calibs.csv" tmap(r -> parse_row(r, defaults), collect(csvrows))

    df = DataFrame(Tables.dictrowtable(cs))
    allowmissing!(df)

    verifications!(df, data_path)

    if any(!isempty, df.issues)
        msg = join([string("row $i: ", join(issues, ", ")) for (i, issues) in enumerate(df.issues) if !isempty(issues)], '\n')
        println('\n' * "The following are issues with the calibs.csv file:\n" * msg)
        if strict
            error("there were issues with the calibration (see above)")
        else
            return df
        end
    end

    return RectificationMethod.(eachrow(df))
end

# Precompile the parse → verify → report pipeline at build time. The bulk of first-call latency is the
# DataFrames/DataFramesMeta/Chain macro machinery (column-typed `@transform!`/`@chain`/`subset`/`verify!`
# specializations), which a single `load_rectifications` run compiles. The workload CSV points at
# nonexistent files (one row per type), so the run exercises the full pipeline for all three types but
# bails before any ffprobe/matread/corner detection — no bundled media needed, fast deterministic
# precompile. (The video-read/corner-detection paths are left to compile on first real use.)
@setup_workload begin
    dir = mktempdir()
    csv = joinpath(dir, "precompile.csv")
    open(csv, "w") do io
        # Minimal header (other columns are back-filled by parse_row); one row per type so all three
        # parse branches and the type-specific verifications compile. All point at a nonexistent file.
        println(io, "calibration_id,file,matlab_file,type,extrinsic,extrinsic_index,scale")
        println(io, "v,nope.mp4,,video,1,,")
        println(io, "m,nope.mp4,nope.mat,matlab,1,1,")
        println(io, "s,nope.mp4,,only_scale,1,,9.5")
    end
    @compile_workload begin
        redirect_stdout(devnull) do
            try
                load_rectifications(dir, csv; strict = false)
            catch
            end
        end
    end
end

end
