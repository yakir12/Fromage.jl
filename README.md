# Fromage 🧀

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://yakir12.github.io/Fromage.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://yakir12.github.io/Fromage.jl/dev/)
[![Build Status](https://github.com/yakir12/Fromage.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/yakir12/Fromage.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Build Status](https://app.travis-ci.com/yakir12/Fromage.jl.svg?branch=main)](https://app.travis-ci.com/yakir12/Fromage.jl)
[![Coverage](https://coveralls.io/repos/github/yakir12/Fromage.jl/badge.svg?branch=main)](https://coveralls.io/github/yakir12/Fromage.jl?branch=main)

This is the main package used to organise, calibrate, and track video files in the Dacke lab.  

## When is this useful
You have runs as well as calibrations recorded in video files and you want to extract the tracks as trajectories with real-world coordinates.

## Install
You'll need a new version of Julia installed (see [here](https://julialang.org/downloads/) for instructions on how to install Julia).

Start a new Julia REPL (e.g. by double-clicking the Julia icon). In the new terminal, type a right-hand-square-bracket (`]`) and then copy-paste `add https://github.com/yakir12/Fromage.jl`, followed by pressing `Enter`:
```julia
] add https://github.com/yakir12/Fromage.jl
```

## How
You'll need a `runs.csv` file and a `calibs.csv` file (both can actually be multiple files spread across multiple directories, following your preferred organisational needs). Each row in the `runs.csv` file represents a single run, while each row in the `calibs.csv` file represents a single calibration. Both can have as many rows as needed.

To organise, calibrate, and track all your data run the `main` function on the path to the folder that contains all the `run.csv`, `calibs.csv`, and video files:
```julia
main("the/path/to/all/the/files")
```

### Runs
In the `runs.csv` file you have to include both of the following columns, and no entry may be missing:

1. `file`: the video file name (including its file extension, e.g. `video.mp4`).
2. `calibration_id`: the unique ID for the calibration that should be used to calibrate this specific run (specified in the `calibs.csv` file). One good suggestion is the row number of corresponding calibration in the `calibs.csv` file (i.e. `1`, `2`, ...), but could be any unique identifier.

The following additional settings have default values:
1. `runs_path`: the path to the video file, relative to the location of the bespoke csv file. Defaults to the same path of the `runs.csv` file.
2. `runs_start`: the time-stamp of when the run started in the video file. The format is either a number of seconds (e.g. `12.345`), or HH:MM:SS.mmm, for example, 2 minutes and 9 seconds and 123 milliseconds looks like `00:02:09.123`. If you don't need millisecond accuracy just omit them (i.e. `00:02:09`). Defaults to `0` (i.e. the beginning of the video).
3. `runs_stop`: when the run ends (same format as for `start`). Defaults to the full duration of the video.
4. `start_xy`: the pixel coordinate in the frame where the tracker will start its search for the target. One of the following options are available:
    - A string, `"(x,y)"` (including the quotation marks, `"`) where `x` and `y` are the horizontal and vertical pixel-distances between the left-top corner of the video-frame and the center of the target at `start`. 
    - An integer, `i`: the last position (i.e. the xy coordinate at `stop`) in the `i`th run in the bespoke `runs.csv` file is the starting position for this run.
    - If `start_xy` is missing, the target will be detected in a large (half as large as the frame) window centered at the frame. 
The default value of `start_xy` is explained [below](#how-setting-the-start_xy-works).
5. `target_width`: the full pixel-width of the target (diameter, not radius). The default value is 60 pixels.
6. `window_size`: A string `"(w,h)"` where `w` and `h` are the width and height of the window (i.e. region of interest) in which the tracker will detect the target. This should be larger than the `target_width` and relate to how fast the target moves between subsequent frames. Defaults to 1.5 times the target width.

### Calibrations
In the `calibs.csv` file you have to include both of the following columns, and no entry may be missing:
1. `file`: the video file name (including its file extension, e.g. `video.mp4`).
2. `extrinsic`: when the checkerboard is flat on the arena's surface (same format as for `runs_start` or `calibs_start`)

The following additional settings have default values:
1. `calibs_path`: the path to the video file, relative to the location of the bespoke csv file. Defaults to the same path of the `calibs.csv` file.
2. `calibration_id`: some unique identifier for this specific calibration. Defaults to `1`, `2`, `3`, ... `n`, where `n` is the number of rows in the `calibs.csv` file.
3. `calibs_start`: the time-stamp of when the intrinsic calibration started, in the following format HH:MM:SS.mmm, for example, 2 minutes and 9 seconds and 123 milliseconds looks like `00:02:09.123`. If you don't need millisecond accuracy just omit them (i.e. `00:02:09`). Defaults to 0 (i.e. the beginning of the video).
4. `calibs_stop`: when the intrinsic calibration ends (same format as for `start`). Defaults to the full duration of the video.
5. `checker_size`: the width of the checkers in the checkerboard in real-world units (e.g. cm). The default value is 4.
6. `n_corners`: the number of internal corners for each side of the checkerboard. The default value is (5, 8).
7. `temporal_step`: sample the video every `temporal_step` seconds between the start and stop timestamps. So for a 10 second long calibration, a `temporal_step` of 2 seconds will result in 6 images that the calibration will use. The default value is 2.
8. `center`: the pixel-coordinate of the center of the arena . Defaults to missing.
9. `north`: the pixel-coordinate of the direction of the North relative to the center of the arena . Defaults to missing.

### Changing the defaults
You can change the default settings either globally by creating a preferences file, or per individual run/calibration by adding a column to the `runs.csv`/`calibs.csv` files and specifying the new value for each row, or a mix of both by specifying the global values in the preferences file *and* adding a column to the csv file.

#### The preferences file
To change the global default settings create a file called `LocalPreferences.toml` in the directory where you run your analysis from. Include in the file the title of this package (i.e. `[Fromage]`) and all the settings you wish to change. For example, if you want to change the size of the checker to 10, the number of inner corners to (7,9), the width of the target to 18, and the temporal step to 0.33, then the contents of the preferences file would be:
```toml
[Fromage]
checker_size = 10
n_corners = "(7, 9)"
target_width = 18
temporal_step = 0.33
```

You can thus change the defaults of all the "additional settings" (e.g. `runs_path`, `runs_start`, `center`, etc.).

#### How setting the start_xy works
Apart from setting the `start_xy` to a coordinate, an integer, or omitting it altogether (see the description for `start_xy` [above](#runs)), the `center` (from the `calibs.csv` file) of the arena -- if not missing -- sets the `start_xy` as well. The hierarchy of which value trumps which is:
If `start_xy` is not missing (i.e. its a coordinate or an integer) from the `runs.csv` file, use it, otherwise look at the `center` column in the `calibs.csv` file.
If `center` is not missing from the `calibs.csv` file, use it, otherwise look at the `start_xy` entry in the `LocalPreferences.toml` file.
If `start_xy` is not missing from the `LocalPreferences.toml` file, use it, otherwise the target will be detected in a large (half as large as the frame) window centered at the frame. 

In summary: `start_xy in runs.csv → center in calibs.csv → start_xy in LocalPreferences.toml → center of frame & large window_size`

## Additional details (this will be moved to analysis instead)
`Fromage.jl` will attempt to retrieve EXIF metadata from the video files pertaining the date and time the video was recorded. This in turn is used to determine the date and time of each run. If the station where the run occurred is included either as an entry in the `LocalPreferences.toml` file or per row in the `runs.csv` file (in case the data comes from multiple stations), the elevation and azimuth of the sun at the time of the run are also calculated.
