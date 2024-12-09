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
You'll need a `runs.csv` file and a `calibs.csv` file (both can actually be multiple files spread across multiple directories, following your prefered organisational needs). Each row in the `runs.csv` file represents a single run, while each row in the `calibs.csv` file represents a single calibration. Both can have as many rows as needed.

### Runs
In the `runs.csv` file you have to include all of the following columns, and no entry may be missing:

1. `file`: the video file name (including its file extension, e.g. `path/video.mp4`).
2. `calibration_id`: the unique ID for the calibration that should be used to calibrate this specific run (specified in the `calibs.csv` file).

The following additional settings have default values:
1. `runs_path`: the path to the video file, relative to the location of the bespoked csv file. Defaults to the same path of the bespoked `runs.csv` file.
2. `runs_start`: the time-stamp of when the run started in the video file. The format is HH:MM:SS.mmm, for example, 2 minutes and 9 seconds and 123 milliseconds looks like `00:02:09.123`. If you don't need millisecond accuracy just ommit them (i.e. `00:02:09`). Defaults to 0 (i.e. the begining of the video).
3. `runs_stop`: when the run ends (same format as for `start`). Defaults to the full duration of the video.
4. `start_xy`: the pixel coordinate in the frame where the tracker will start its search for the target. One of the following options are available:
    - A string, `"(x,y)"` (including the quotation makrs, `"`) where `x` and `y` are the horizontal and vertical pixel-distances between the left-top corner of the video-frame and the center of the target at `start`. 
    - An integer, `i`: the last position (i.e. the xy coordinate at `stop`) in the `i`th run in the bespoked`runs.csv` file is the starting position for this run.
    - If `start_xy` is missing, the target will be detected in a large (half as large as the frame) window centered at the frame. 
The default value of `start_xy` is explained [below](####how-setting-the-start_xy-works).
5. `target_width`: the full pixel-width of the target (diameter, not radius). The default value is 25 pixels.
6. `window_size`: A string `"(w,h)"` where `w` and `h` are the width and height of the window (i.e. region of interest) in which the tracker will detect the target. This should be larger than the `target_width` and relate to how fast the target moves between subsequent frames. Defaults to 1.5 times the target width.


### Calibrations
In the `calibs.csv` file you have to include all of the following columns, and no entry may be missing:
1. `file`: the video file name (including its file extension, e.g. `video.mp4`).
2. `extrinsic`: when the checkerboard is flat on the arena's surface (same format as for `start`)

The following additional settings have default values:
1. `calibs_path`: the path to the video file, relative to the location of the bespoked csv file. Defaults to the same path of the bespoked `runs.csv` file.
2. `calibration_id`: some unique ID for this specific calibration. One common choice is the name of the video file containing the calibration, however this quickly breaks down if you have more than one calibration in one video file. Defaults to the name of the calibration video file name.
3. `calibs_start`: the time-stamp of when the intrinsic calibration started, in the following format HH:MM:SS.mmm, for example, 2 minutes and 9 seconds and 123 milliseconds looks like `00:02:09.123`. If you don't need millisecond accuracy just ommit them (i.e. `00:02:09`). Defaults to 0 (i.e. the begining of the video).
4. `calibs_stop`: when the intrinsic calibration ends (same format as for `start`). Defaults to the full duration of the video.
5. `checker_size`: the width of the checkers in the checkerboard in real-world units (e.g. cm). The default value is 3.9.
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

#### How setting the start_xy works
Apart from setting the `start_xy` to a coordinate, an integer, or omitting it altogether (see the description for `start_xy` [above](###runs)), the `center` (from the `calibs.csv` file) of the arena -- if not missing -- sets the `start_xy` as well. The hiearchy of which value trumps which is:
If `start_xy` is not missing (i.e. its a coordinate or an integer) from the `runs.csv` file, use it, otherwise look at the `center` column in the `calibs.csv` file.
If `center` is not missing from the `calibs.csv` file, use it, otherwise look at the `start_xy` entry in the `LocalPreferences.toml` file.
If `start_xy` is not missing from the `LocalPreferences.toml` file, use it, otherwise the target will be detected in a large (half as large as the frame) window centered at the frame. 

In summary: `start_xy in runs.csv → center in calibs.csv → start_xy in LocalPreferences.toml → center of frame & large window_size`
