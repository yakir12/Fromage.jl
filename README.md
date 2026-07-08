# Fromage 🧀

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://yakir12.github.io/Fromage.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://yakir12.github.io/Fromage.jl/dev/)
[![Build Status](https://github.com/yakir12/Fromage.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/yakir12/Fromage.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://coveralls.io/repos/github/yakir12/Fromage.jl/badge.svg?branch=main)](https://coveralls.io/github/yakir12/Fromage.jl?branch=main)

This is the main package used to organise, calibrate, and track video files in the Dacke lab.

## When is this useful

You have video recordings of **runs** — an animal (or any other target) moving through an arena — and video recordings of **calibrations** — a checkerboard filmed in that same arena. Fromage tracks the target in every run, pairs each run with its rectification, and gives you everything needed to convert the tracked pixel coordinates into real-world coordinates (e.g. cm on the arena floor). It also produces a diagnostic video so you can quickly check, run by run, that the tracker followed the right thing.

## Install

This repository bundles Fromage's supporting packages (VerifyRectifications, VerifyRuns,
Rectifications, and PawsomeTracker) as submodules — installing Fromage installs everything.

You'll need a recent version of Julia, at least 1.11 (see [here](https://julialang.org/downloads/) for instructions). Then, in Julia's Pkg mode (type `]` at the REPL):

```
pkg> add <path-or-URL-of-this-repository>
```

## Quick start

1. Put your video files together with a `calibs.csv` and a `runs.csv` file in one folder (see [The data folder](#the-data-folder) below).
2. Start Julia with multiple threads — tracking and calibrating are parallelized and this makes a big difference:
   ```sh
   julia --threads=auto
   ```
3. Run:
   ```julia
   using Fromage
   runs = main("the/path/to/your/data/folder")
   ```

`main` then:

1. Reads and **validates every row** of both csv files: files exist and are readable videos, timestamps fall within the video's duration, the checkerboard is actually detectable, all parameters are within sane ranges, etc. If *anything* is wrong it prints one line per problematic row (e.g. `row 3: file does not exist, wrong start format`) and stops before any tracking starts — fix the csv files and run again.
2. Builds a rectification for every run from its referenced `calibs.csv` entry.
3. Tracks the target in every run.
4. Writes a single diagnostic video, `results_dir/diagnostic.mp4`, containing all the runs (see [The diagnostic video](#the-diagnostic-video)).
5. Returns a `DataFrame` with one row per run (see [What you get back](#what-you-get-back)).

## The data folder

The simplest layout is everything in one folder:

```
my experiment/
├── calibs.csv
├── runs.csv
├── calib_morning.mp4
├── calib_afternoon.mp4
├── beetle01.mp4
├── beetle02.mp4
└── ...
```

and then `main("path/to/my experiment")`.

Both csv files can also be named differently or live in subfolders:

```julia
main("path/to/my experiment"; calibs_file = "meta/my_calibs.csv", runs_file = "meta/my_runs.csv")
```

and the video files can live in other folders via the `path` column (paths are relative to the folder the csv file itself is in; absolute paths work too).

### General csv rules

These apply to both `runs.csv` and `calibs.csv`:

- Column **order doesn't matter**, and optional columns may be omitted entirely.
- A **blank cell** in an optional column means "use the default" — so a column can be set for some rows and left blank for others.
- **Unrecognized column names are an error.** Both files accept a free-text `comment` column, which is ignored.
- **Timestamps** (`start`, `stop`, `extrinsic`) are either a number of seconds (e.g. `12.345`) or a clock time `HH:MM:SS.mmm` (e.g. `00:02:09.123`; milliseconds optional). ⚠️ Always write all three clock parts: `01:30` means 1 hour 30 minutes, *not* 1 minute 30 seconds — if in doubt, use plain seconds.
- **Pixel coordinates** (`start_location`, `center`, `north`) are written `"(x, y)"` — including the quotes, since the cell contains a comma — where `x` is the distance in pixels from the *left* edge of the frame and `y` from the *top* edge, exactly as an image viewer (GIMP, Photoshop, etc.) reports them when you hover over the displayed frame.

### Global defaults

The default of every *tuning* column can be overridden globally from `main`. The hierarchy is: a
csv cell always wins over a global default, which wins over the built-in default (including the
value probed from the video, for `yadif` and `fps`):

```julia
main("path/to/data";
     rectification_defaults = (n_corners = (5, 8), blur = 0),
     tracking_defaults      = (target_width = 60, fps = 25))
```

- `rectification_defaults` may set: `checker_size`, `n_corners`, `temporal_step`,
  `radial_parameters`, `blur`, `yadif`.
- `tracking_defaults` may set: `target_width`, `window_size`, `darker_target`, `fps`, `apriltags`,
  `initial_search_factor`, `white_point`, `scale`.

Anything else (identities, file names, timestamps, `start_location`/`center`/`north`) is per-row
only, and an unrecognized or unconvertible entry is rejected with an error before anything runs.
Global values pass through the same validation as csv cells — e.g. a global `fps` must still not
exceed each video's own frame rate. `only_rectify` and `only_track` accept the same keywords.

## runs.csv

One row per run video (a run split across multiple video files uses several rows, see [Runs that span multiple videos](#runs-that-span-multiple-videos)).

### Required columns

| column | description |
| --- | --- |
| `file` | the video file name, including its extension (e.g. `beetle01.mp4`). |
| `calibration_id` | which rectification to use for this run — must match a `calibration_id` in `calibs.csv`. |

### Optional columns

| column | default | description |
| --- | --- | --- |
| `start` | `0` | timestamp where the run starts in the video. |
| `stop` | full duration | timestamp where the run ends. |
| `target_width` | `25` | the full width (diameter, not radius) of the target, in pixels. The single most important tuning parameter — measure it in a paused frame. |
| `start_location` | see [below](#where-the-tracker-starts-looking) | `"(x, y)"` pixel coordinate of the target at `start`. |
| `darker_target` | `true` | `true` if the target is darker than its background, `false` if lighter. |
| `window_size` | computed | the size of the search window the tracker scans around the target's last known position: a single number for a square window (e.g. `41`) or `"(w, h)"` for a rectangle. Must be comfortably larger than `target_width` plus however far the target can move between consecutive frames. The default is computed from `target_width` and a conservative speed estimate, and is usually fine. |
| `fps` | video's frame rate | how many frames per second to track. Lower it for slow targets to speed things up. Cannot exceed the video's own frame rate. |
| `initial_search_factor` | `4` | when no start location is known at all, the target is searched for in a window of size `min(width, height) / initial_search_factor` centered on the frame. Larger values → smaller initial search window. |
| `scale` | `1` | spatial downsampling factor (0 < scale ≤ 1) applied before tracking; e.g. `0.5` tracks on half-resolution frames (faster). Returned coordinates are always in original-resolution pixels. The scaled target (`target_width × scale`) must remain at least 1 pixel wide. |
| `run_id` | row number | identifies the run; only needed for multi-video runs (below). All-or-nothing: either every row has a `run_id`, or none does. |
| `path` | `.` | folder containing `file`, relative to the location of the csv file. |
| `comment` | — | free text, ignored. |

(Two more columns, `apriltags` and `white_point`, are accepted for compatibility but currently have **no effect**.)

### Where the tracker starts looking

The starting position for a run is determined by the first available of:

1. `start_location` in `runs.csv`,
2. the `center` of the run's rectification in `calibs.csv`,
3. nothing — the target is searched for near the center of the frame, within a window of `min(width, height) / initial_search_factor` pixels.

### Runs that span multiple videos

If a single run was recorded across several consecutive video files (e.g. the camera splits long recordings), give all its rows the **same `run_id`**, one row per video file, in chronological order:

```csv
run_id,calibration_id,file,start,stop,start_location
long,afternoon,beetle03_a.mp4,0,,"(210, 400)"
long,afternoon,beetle03_b.mp4,0,00:01:03,
```

- `file`, `start`, `stop`, and `start_location` are per segment; all other parameters (`target_width`, `fps`, `calibration_id`, …) must be identical across the segments of one run, and all segments must come from the same camera setup (same frame size).
- Leave `start_location` blank on the second segment onwards: tracking continues from where the previous segment ended.
- `run_id` is all-or-nothing: as soon as one row has a `run_id`, every row needs one (rows with a `run_id` all of their own are ordinary single-video runs). If no row has one, each row is its own run.

## calibs.csv

One row per rectification. Every rectification is anchored to a video file of the arena. There are two kinds, selected with the `type` column:

- **`video`** (the default): a video of a checkerboard being moved around the arena, then laid flat on the arena floor. Yields a full rectification — lens distortion, perspective, and scale.
- **`only_scale`**: no checkerboard; you supply a fixed scale (real-world units per pixel). No distortion or perspective correction — appropriate for e.g. distortion-free footage filmed straight down.

### Columns for `type = video`

Required:

| column | description |
| --- | --- |
| `calibration_id` | a unique name for this rectification; referenced from `runs.csv`. |
| `file` | the video file name, including extension. |
| `extrinsic` | timestamp of a frame where the checkerboard lies **flat on the arena floor**. This frame anchors the mapping between the image and the arena surface, so make sure the full board is clearly visible in it. |

Optional:

| column | default | description |
| --- | --- | --- |
| `start`, `stop` | — | the time window during which the checkerboard is being moved around (tilted, shifted) for the internal camera calibration. Provide both or neither. The window must be long enough to contain at least 3 sampled frames with a detectable checkerboard (see `temporal_step`). When **both** are omitted the calibration is fit from the single `extrinsic` frame alone, and lens distortion is disregarded — only appropriate for distortion-free lenses; otherwise film a calibration window and provide it. |
| `checker_size` | `4` | side length of a single checker square, in the real-world unit of your choice (e.g. cm). **The resulting track coordinates come out in this unit.** |
| `n_corners` | `"(7, 10)"` | number of *internal* corners of the checkerboard along its two sides (a board of 8 × 11 squares has 7 × 10 internal corners). |
| `temporal_step` | `2.0` | sample one frame every `temporal_step` seconds within [`start`, `stop`]. E.g. a 30-second window at the default yields 16 candidate frames. Ignored without a calibration window. |
| `center` | — | `"(x, y)"` pixel coordinate of the arena's center. Becomes the **origin** of the real-world coordinate system, and doubles as the default starting location for this rectification's runs. |
| `north` | — | `"(x, y)"` pixel coordinate of a point lying due north of `center`. Rotates the real-world coordinates so that north is consistent across rectifications. Requires `center`. |
| `blur` | `1` | Gaussian blur (sigma, in pixels) applied to frames before corner detection; helps with noisy/sharpened footage. `0` disables. |
| `radial_parameters` | `1` | number of radial lens-distortion coefficients to fit (1–3). More isn't automatically better — use 2–3 only for strongly distorting (e.g. fisheye) lenses. Ignored without a calibration window. |
| `path` | `.` | folder containing `file`, relative to the location of the csv file. |
| `aspect` | read from video | pixel aspect ratio; only override for anamorphic footage that misreports it. |
| `yadif` | read from video | `true` to deinterlace interlaced footage; detected automatically, override to force. |
| `type` | `video` | see above. |

### Columns for `type = only_scale`

Required: `calibration_id`, `file`, `extrinsic` (a timestamp of any representative frame), and:

| column | description |
| --- | --- |
| `scale` | real-world units per pixel (e.g. cm/pixel). |

Optional: `path`, `center`, `north`, `aspect` — same meaning as above.

Both kinds can be mixed in one file — leave a column blank on the rows where it doesn't apply:

```csv
calibration_id,type,file,extrinsic,start,stop,checker_size,n_corners,center,north,scale
morning,video,calib_morning.mp4,00:00:02,00:00:05,00:00:35,4,"(7, 10)","(960, 540)","(960, 100)",
afternoon,,calib_afternoon.mp4,1.5,5,35,4,"(7, 10)","(955, 545)",,
drone,only_scale,drone_shot.mp4,0,,,,,"(2000, 1500)",,0.21
```

### What makes a good calibration video

- Film the checkerboard at the same location and with the exact same camera settings (zoom, resolution, mounting) as the runs it will calibrate.
- During [`start`, `stop`], move and tilt the board through the volume where the animal will be — variety of poses is what constrains the lens model.
- Then lay the board flat on the arena floor and note that timestamp — that's your `extrinsic`.
- Keep the full board visible and unobstructed; avoid motion blur (move slowly) and glare.

## What gets validated

Before anything is tracked, every row of both files is checked, including (not exhaustive):

- all referenced files and folders exist, and the videos are actually readable;
- timestamps are well-formatted, non-negative, ordered (`start` < `stop`), and within the video's duration;
- pixel coordinates lie inside the frame;
- numeric parameters are within their valid ranges;
- `calibration_id`s are unique, and no two rectifications are effectively identical duplicates;
- the checkerboard is detected at the `extrinsic` timestamp, and — when a calibration window is given — at least 3 sampled frames within [`start`, `stop`] have a detectable board (this is the expensive part of validation — it reads real frames);
- segments of a multi-video run agree on all their shared parameters;
- every `calibration_id` used in `runs.csv` exists in `calibs.csv`.

All problems are reported at once, per row, and nothing runs until they're all fixed.

## What you get back

`main` returns a `DataFrame` with one row per run:

| column | content |
| --- | --- |
| `run_id`, `calibration_id` | the identifiers from the csv files. |
| `run` | the track: a tuple `(ts, coords)` of timestamps (seconds into the video) and pixel coordinates (`(row, col)` of the target in the original frame). |
| `rectification` | the rectification: a named tuple whose `image2real` function converts pixel coordinates to real-world coordinates (origin at `center`, north-aligned if `north` was given, in `checker_size`/`scale` units); `real2image` is its inverse. |
| `r`, `c` | the parsed run and rectification entries (all the resolved parameter values). |

For example:

```julia
runs = main("path/to/data")
ts, coords = runs.run[1]                       # first run: timestamps + pixel coordinates
xy = runs.rectification[1].image2real.(coords)   # real-world coordinates, e.g. in cm
```

## The diagnostic video

`main` writes `results_dir/diagnostic.mp4` (in the folder Julia was started in): every run rendered top-down through its rectification, with a circle around the tracked position, a trailing trace, and the video's file name as a label — one run after the other. **Watch it.** It is the fastest way to catch a tracker that latched onto a shadow, a wrong starting position, or a bad rectification.

## Running only part of the pipeline

Two unexported helpers are useful while iterating on the csv files:

```julia
# only build rectifications (all of them, or a subset of calibration_ids):
Fromage.only_rectify("path/to/data"; calibs_file = "calibs.csv", todo = ["morning"])

# only track (no rectification involved), optionally a subset of rows;
# writes one raw-view diagnostic per run: results_dir/1.mp4, 2.mp4, ...
Fromage.only_track("path/to/data"; runs_file = "runs.csv", rows = 3:5)
```

Both still run the full validation of their respective csv file.

## Example files

Template csv files demonstrating the happy path live in [`examples/`](examples/): [`examples/runs.csv`](examples/runs.csv) and [`examples/calibs.csv`](examples/calibs.csv). They reference placeholder video file names — swap in your own.
