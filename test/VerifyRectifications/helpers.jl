using Test
using Fromage: VerifyRectifications
using CSV, DataFrames
using FFMPEG, MAT

const VRect = VerifyRectifications

# ---------------------------------------------------------------------------
# Artifact generation (videos, matlab files) into a shared directory.
# ---------------------------------------------------------------------------

function make_video(path; duration = 10, size = (640, 480))
    w, h = size
    FFMPEG.ffmpeg_exe(`-y -loglevel error -f lavfi -i testsrc=duration=$duration:size=$(w)x$(h):rate=30 -pix_fmt yuv420p $path`)
    path
end

function make_checkerboard_video(path, png; duration = 10)
    pad = "pad=ceil(iw/2)*2:ceil(ih/2)*2"   # libx264/yuv420p needs even dimensions
    FFMPEG.ffmpeg_exe(`-y -loglevel error -framerate 10 -loop 1 -i $png -t $duration -vf $pad -pix_fmt yuv420p $path`)
    path
end

make_corrupt_video(path) = (write(path, rand(UInt8, 500)); path)

# The first `board_t` seconds show the (padded, 500×376) checkerboard, the rest is cornerless
# testsrc footage: an extrinsic inside the board portion detects fine while a calibs window over
# the tail does not — this drives verify_intrinsics! (which needs ≥ 3 detectable-corner frames).
function make_mixed_video(path, png; board_t = 2, total = VIDEO_DURATION)
    rest = total - board_t
    FFMPEG.ffmpeg_exe(`-y -loglevel error -framerate 10 -loop 1 -t $board_t -i $png
                       -f lavfi -i testsrc=duration=$rest:size=500x376:rate=10
                       -filter_complex "[0:v]pad=ceil(iw/2)*2:ceil(ih/2)*2,setsar=1,format=yuv420p[a];[1:v]setsar=1,format=yuv420p[b];[a][b]concat=n=2:v=1"
                       -pix_fmt yuv420p $path`)
    path
end

# Interlaced footage: the `interlace` filter plus the interlaced-coding flags make ffprobe report a
# `field_order` of "tt", which is what read_video_metadata! maps to yadif = true. (testsrc itself is
# progressive, so without these flags field_order is "progressive" -> yadif = false.)
function make_interlaced_video(path; duration = 2, size = (720, 576))
    w, h = size
    FFMPEG.ffmpeg_exe(`-y -loglevel error -f lavfi -i testsrc=duration=$duration:size=$(w)x$(h):rate=25 -vf interlace -flags +ildct+ilme -pix_fmt yuv420p $path`)
    path
end

# Dummy stand-ins for the fields CameraCalibrations.jl needs; verify_matlab_structure! only checks
# that each key is present, so the values are arbitrary. TranslationVectors/RotationVectors are (N×3),
# one row per extrinsic pose, mirroring a real cameraParams.mat (which is 6×3) — the row count N is what
# the extrinsic_index bounds check reads, so it must be a realistic multi-pose shape, not 1×3.
const MATLAB_N_EXTRINSICS = 6
const MATLAB_CALIB_FIELDS = Dict("TranslationVectors" => zeros(MATLAB_N_EXTRINSICS, 3),
                                 "RotationVectors"    => zeros(MATLAB_N_EXTRINSICS, 3),
                                 "RadialDistortion"   => [0.0, 0.0],
                                 "K"                  => [1.0 0.0 0.0; 0.0 1.0 0.0; 0.0 0.0 1.0])

# matlab stores ImageSize as [height, width]; the reader reverses it -> (width, height). The default
# (480, 640) -> (640, 480) matches video.mp4 (640×480), the matlab rows' source video, so the
# ImageSize/source-video cross-check passes on the happy path.
make_matlab(path; imagesize = (480, 640)) = (MAT.matwrite(path, merge(Dict("ImageSize" => collect(imagesize)), MATLAB_CALIB_FIELDS)); path)
make_matlab_no_imagesize(path) = (MAT.matwrite(path, Dict("not_a_calibration" => [1, 2, 3])); path)
make_bad_matlab(path) = (write(path, "this is not a mat file"); path)
# ImageSize present, but only some required calibration fields (missing TranslationVectors, RotationVectors)
make_matlab_partial(path; imagesize = (480, 640)) = (MAT.matwrite(path, Dict("ImageSize" => collect(imagesize), "RadialDistortion" => [0.0, 0.0], "K" => [1.0 0.0; 0.0 1.0])); path)
# ImageSize buried in a sub-struct, as real MATLAB calibration files store it (exercises findfirstkey recursion)
make_matlab_nested(path; imagesize = (480, 640)) = (MAT.matwrite(path, Dict("cameraParams" => merge(Dict("ImageSize" => collect(imagesize)), MATLAB_CALIB_FIELDS))); path)
# TranslationVectors (6×3, from MATLAB_CALIB_FIELDS) and RotationVectors (overridden to 5×3) disagree on
# the number of extrinsic poses -> matlab_extrinsic_count returns an issue instead of a count.
make_matlab_mismatch(path; imagesize = (480, 640)) = (MAT.matwrite(path, merge(MATLAB_CALIB_FIELDS, Dict("ImageSize" => collect(imagesize), "RotationVectors" => zeros(5, 3)))); path)

# Kept as short as the tests allow: ffmpeg encoding dominates artifact setup, so shorter videos
# load faster. Two floors now apply: (1) the largest `extrinsic` time stamp any *clean* row uses,
# since verify_extrinsics! seeks there (s_ok extracts at 00:00:03); and (2) the baseline videorow's
# calibs window, which IS validated against the duration (stop ≤ duration) — its window is
# 0…4 s, so the video must be longer than 4 s. 5 s satisfies both with a 1 s margin.
const VIDEO_DURATION = 5

"Generate every shared artifact into `dir`; return a NamedTuple of their basenames."
function setup_artifacts(dir)
    checkerboard_png = joinpath(@__DIR__, "fixtures", "checkerboard.png")
    make_video(joinpath(dir, "video.mp4"); duration = VIDEO_DURATION, size = (640, 480))      # dim (640,480)
    make_checkerboard_video(joinpath(dir, "board.mp4"), checkerboard_png; duration = VIDEO_DURATION) # dim (500,376)
    make_mixed_video(joinpath(dir, "mixed.mp4"), checkerboard_png)                  # board 0–2 s, testsrc 2–5 s
    make_corrupt_video(joinpath(dir, "corrupt.mp4"))
    make_interlaced_video(joinpath(dir, "interlaced.mp4"))                          # field_order tt -> yadif true
    make_matlab(joinpath(dir, "good.mat"); imagesize = (480, 640))                 # dim (640,480), matches video.mp4
    make_matlab_no_imagesize(joinpath(dir, "noimsize.mat"))
    make_bad_matlab(joinpath(dir, "bad.mat"))
    make_matlab_partial(joinpath(dir, "partialcalib.mat"))                         # missing 2 required fields
    make_matlab_nested(joinpath(dir, "nested.mat"); imagesize = (480, 640))        # dim (640,480), matches video.mp4
    make_matlab_mismatch(joinpath(dir, "mismatch.mat"))                            # translation/rotation pose counts differ
    return (video = "video.mp4", board = "board.mp4", mixed = "mixed.mp4", corrupt = "corrupt.mp4", interlaced = "interlaced.mp4",
            good_mat = "good.mat", noimsize_mat = "noimsize.mat", bad_mat = "bad.mat",
            partial_mat = "partialcalib.mat", nested_mat = "nested.mat", mismatch_mat = "mismatch.mat")
end

# ---------------------------------------------------------------------------
# CSV building. One canonical header; `row(; ...)` fills absent cells with missing.
# Only names from VerifyRectifications.COLUMNS are allowed (others => "unrecognized column").
# ---------------------------------------------------------------------------

const HEADER = ["calibration_id", "path", "file", "matlab_file", "type", "extrinsic", "extrinsic_index",
                "start", "stop", "center", "north", "n_corners",
                "checker_size", "scale", "temporal_step", "radial_parameters", "blur",
                "yadif", "aspect"]

row(; kw...) = [get(kw, Symbol(c), missing) for c in HEADER]

# Clean baseline rows per rectification type; override any field via keyword to isolate one issue.
# (Each scenario is loaded as its own single-row CSV, so there is no cross-row coupling.)
_merge(base; kw...) = row(; merge(base, values(kw))...)
videorow(; kw...) = _merge((calibration_id = "v", path = ".", file = ART.board, type = "video",
                            extrinsic = "00:00:01", start = "00:00:00", stop = "00:00:04",
                            center = (250, 180), north = (250, 1), n_corners = (5, 8),
                            checker_size = 4, temporal_step = 2, radial_parameters = 1, blur = 0); kw...)
matlabrow(; kw...) = _merge((calibration_id = "m", path = ".", file = ART.video, matlab_file = ART.good_mat,
                             type = "matlab", extrinsic = "00:00:01", extrinsic_index = 1,
                             center = (160, 120), north = (160, 1)); kw...)
scalerow(; kw...) = _merge((calibration_id = "s", path = ".", file = ART.video, type = "only_scale",
                            extrinsic = "00:00:01", scale = 9.5, center = (320, 240), north = (320, 1)); kw...)
# mixed.mp4: checkerboard for 0–2 s, testsrc after; extrinsic sits on the board, the calibs window
# is chosen per test (inside/outside the board portion) to exercise the intrinsic-window check.
mixedrow(; kw...) = _merge((calibration_id = "x", path = ".", file = ART.mixed, type = "video",
                            extrinsic = "00:00:01", start = "0", stop = "1.8",
                            center = (250, 180), north = (250, 1), n_corners = (5, 8),
                            checker_size = 4, temporal_step = 0.9, radial_parameters = 1, blur = 0); kw...)

csvcell(::Missing) = ""
function csvcell(x)
    s = x isa AbstractString ? String(x) : string(x)
    (occursin(',', s) || occursin('"', s)) ? string('"', replace(s, '"' => "\"\""), '"') : s
end

function write_csv(path, rows; header = HEADER)
    open(path, "w") do io
        println(io, join(header, ","))
        for r in rows
            println(io, join(csvcell.(r), ","))
        end
    end
    path
end

# ---------------------------------------------------------------------------
# Run + assert. DATADIR is defined in runtests.jl before any test file runs.
# ---------------------------------------------------------------------------

"Write `rows` to a CSV in DATADIR and load it. Scenario rows keep indices 1:length(rows).
(`parse_row` back-fills every COLUMNS entry with missing, so even a single-type CSV has every
column `verifications!` references — no column-completing filler rows are needed.)"
function check(name, rows; strict = false, header = HEADER, defaults = (;))
    csv = write_csv(joinpath(DATADIR, name), rows; header)
    VRect.load_rectifications(DATADIR, csv; strict, defaults)
end

"Like `check`, but also capture what load_rectifications prints to stdout. Returns (df, output).
Routed through a temp file because redirect_stdout needs a real file descriptor, not an IOBuffer."
function load_capturing(name, rows; strict = false)
    mktemp() do path, io
        df = redirect_stdout(() -> check(name, rows; strict), io)
        flush(io)
        df, read(path, String)
    end
end

flagged(df, r, sub) = hasproperty(df, :issues) && any(m -> occursin(sub, m), df.issues[r])
# A clean load drops the :issues column (load_rectifications returns select(df, Not(:issues)));
# a load with issues keeps it. So "clean" means the column is gone (or, defensively, all empty).
clean(df) = !hasproperty(df, :issues) || all(isempty, df.issues)
