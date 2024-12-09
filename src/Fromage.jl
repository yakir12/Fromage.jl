module Fromage

# CameraCalibrationFit, CameraCalibrationMeta, SimpTrack

# Preferences, Dates, UUIDs, CSV, DataFrames, VideoIO, FileIO, Colors, ImageTransformations, ImageDraw, OhMyThreads, ProgressMeter

using Preferences
using Dates, UUIDs
using CSV, DataFrames
using VideoIO, FileIO, Colors, ImageTransformations, ImageDraw
using OhMyThreads, ProgressMeter

using CameraCalibrations, PawsomeTracker
# using CameraCalibrationMeta, CameraCalibrationFit, SimpTrack

set_preferences!(Fromage, "checker_size" => 3.9,
                  "n_corners" => "(5, 8)",
                  "temporal_step" => 2.0,
                  "object_width" => 60,
                  "results_dir" => "tracks and calibrations";
                  export_prefs = true)

fun() = (@load_preference("checker_size"), @load_preference("n_corners"), @load_preference("temporal_step"), @load_preference("object_width"))

include("quality.jl")
include("functions.jl")
include("calibrate.jl")
include("track.jl")

export main

function main(data_path::String)
    results_dir = @load_preference("results_dir")
    mkpath(results_dir)
    calibs = get_calib_df(data_path)
    runs = get_runs_df(data_path, calibs)
    # TODO: test for cross quality

    calibrate_all(calibs, results_dir, data_path)
    track_all(runs, results_dir, data_path)
end

end # module Fromage

# TODO:
# General things I could do myself
# Get the start time of each roll (recording time of the camera + timestamp of each roll)
# Get the elevation for each roll thanks to the start time
# Actual data I would like to retrieve from the tracking
# For the second and third roll, the exit angle at 15cm, 30cm, 150cm
# For the first angle, the exit angle depending on the condition:
# If condition 1, exit angle at 15cm OR max
# if condition 2, exit angle at 15cm and 30cm OR max
# if condition 3, exit angle at 15cm, 30cm and 150cm OR max
# → Get everything in a dataframe in the end.
