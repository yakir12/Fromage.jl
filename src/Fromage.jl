module Fromage

# CameraCalibrationFit, CameraCalibrationMeta, SimpTrack

# Preferences, Dates, UUIDs, CSV, DataFrames, VideoIO, FileIO, Colors, ImageTransformations, ImageDraw, OhMyThreads, ProgressMeter
#

using Preferences
using Dates, UUIDs
using CSV, DataFrames, Missings
using VideoIO, FileIO, Colors, ImageTransformations, ImageDraw
using OhMyThreads, ProgressMeter

using CameraCalibrations, PawsomeTracker
# using CameraCalibrationMeta, CameraCalibrationFit, SimpTrack

exiftool_base = joinpath(@__DIR__(), "..", "deps", "src", "exiftool", "exiftool")
const exiftool = exiftool_base*(Sys.iswindows() ? ".exe" : "")

# dict = TOML.parsefile(joinpath(@__DIR__(), "..", "Stations.toml"))["stations"]
# const STATIONS = Dict(v["name"] => v for v in values(dict))

const calibs_preferences = (checker_size = 4, 
                            n_corners = "(5, 8)",
                            temporal_step = 2.0,
                            calibs_path = ".",
                            calibs_start = 0,
                            calibs_stop = 86399.999, # here, we assume that no video will be longer than 23:59:59.999... Hope this holds
                            north = missing,
                            center = missing)

const runs_preferences = (target_width = 60,
                          runs_start = 0,
                          runs_stop = 86399.999, # same
                          runs_path = ".",
                          start_xy = missing,
                          window_size = missing)

preferences = filter(!ismissing, merge(calibs_preferences, runs_preferences, (;results_dir = "tracks and calibrations")))

set_preferences!(Fromage, [String(k) => v for (k, v) in pairs(preferences)]...; export_prefs = true)
# @set_preferences!((String(k) => v for (k, v) in pairs(preferences))...)

# fun1() = Base.get_preferences()
# fun() = (@load_preference("checker_size"), @load_preference("n_corners"))

include("quality.jl")
include("functions.jl")
include("calibrate.jl")
include("track.jl")
# include("sun.jl")

export main

function main(data_path::String)
    results_dir = @load_preference("results_dir")
    mkpath(results_dir)

    calibs = get_df(data_path, "calibs")
    runs = get_df(data_path, "runs")

    io = IOBuffer()

    calib_quality!(calibs, io, data_path)
    runs_quality!(runs, io, data_path)
    both_quality!(calibs, io, runs)

    bytes = take!(io)
    close(io)
    if !isempty(bytes)
        error(String(bytes))
    end

    calibrate_all(calibs, results_dir, data_path)
    track_all(runs, results_dir, data_path)
end

end # module Fromage


# TODO:
# think about how to deal with the station thing and the analysis: move sun elevation etc to analysis
# avoid writing to disk for the calibration
# Actual data Bastien would like to retrieve from the tracking
# For the second and third roll, the exit angle at 15cm, 30cm, 150cm
# For the first angle, the exit angle depending on the condition:
# If condition 1, exit angle at 15cm OR max
# if condition 2, exit angle at 15cm and 30cm OR max
# if condition 3, exit angle at 15cm, 30cm and 150cm OR max
# → Get everything in a dataframe in the end.
