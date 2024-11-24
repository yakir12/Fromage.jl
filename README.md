# Fromage

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://yakir12.github.io/Fromage.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://yakir12.github.io/Fromage.jl/dev/)
[![Build Status](https://github.com/yakir12/Fromage.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/yakir12/Fromage.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Build Status](https://app.travis-ci.com/yakir12/Fromage.jl.svg?branch=main)](https://app.travis-ci.com/yakir12/Fromage.jl)
[![Coverage](https://coveralls.io/repos/github/yakir12/Fromage.jl/badge.svg?branch=main)](https://coveralls.io/github/yakir12/Fromage.jl?branch=main)

This is the main package used to organise, calibrate, and track video files with the help of csv files in the Dacke lab.  

## When is this useful
You have runs as well as calibrations recorded in video files and you want to extract the tracks as trajectories with real-world coordinates.

## How
To do that you'll need a `runs.csv` file and a `calib.csv` file (both can actually be multiple files spread across multiple directories, following your prefered organisational needs). Each row in the `runs.csv` file represents a single run, while each row in the `calib.csv` file represents a single calibration.
### Runs
In the `runs.csv` file you have to include all of the following columns, and no entry may be missing:
1. `path`: the path to the video file, relative to the location of the bespoked csv file.
2. `file`: the video file name (including its file extension, e.g. `mp4`).
3. `start`: the time-stamp of when the run started, in the following format HH:MM:SS.mmm, for example: 00:00:09.123 (the milliseconds are not mandatory, and can be omitted).
4. `stop`: when the run ends (same format as for `start`).
5. `calibration_id`: the unique ID for the calibration that should be used to calibrate this specific run (specified in the `calib.csv` file).

The following additional settings have default values:
1. `start_location`: the pixel location in the frame where the tracker will start its search for the target. The default vale is the center of the frame.
2. `object_width`: the width of the target (in pixels). The default value is 60 pixels.


### Calibrations
In the `calib.csv` file you have to include all of the following columns, and no entry may be missing:
1. `calibration_id`: some unique ID for this specific calibration, can be the name of the video file containing the calibration
2. `path`: the path to the video file, relative to the location of the bespoked csv file.
3. `file`: the video file name (including its file extension, e.g. `mp4`).
3. `start`: the time-stamp of when the intrinsic calibration started, in the following format HH:MM:SS.mmm, for example: 00:00:09.123 (the milliseconds are not mandatory, and can be omitted).
5. `stop`: when the intrinsic calibration ends (same format as for `start`)
6. `extrinsic`: when the checkerboard is flat on the arena's surface (same format as for `start`)

The following additional settings have default values:
1. `checker_size`: the size of the width of the checkers in the checkerboard in real-world units (e.g. cm). The default value is 3.9.
2. `n_corners`: the number of corners for each side of the checkerboard. The default value is (5, 8).
3. `temporal_step`: sample the video every `temporal_step` seconds between the start and stop timestamps. So for a 10 second long calibration, a `temporal_step` of 2 seconds will result in 6 images that the calibration will use. The default value is 2.

## Changing the defaults
You can change the default settings either globally by creating a preferences file, or per run by adding a column to the `runs.csv` file and specifying the new value for each run, or a mix of both by specifying the global values in the preferences file *and* adding a column to the csv file.
