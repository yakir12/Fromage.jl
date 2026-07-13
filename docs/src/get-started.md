# Get started

This page takes you from nothing to your first tracked videos. You'll do three things: install Julia, install Fromage, and run your first analysis.

## 1. Install Julia

Fromage needs Julia **1.11 or newer**. Follow the instructions at [julialang.org/downloads](https://julialang.org/downloads/) — the recommended `juliaup` installer keeps Julia up to date for you.

!!! warning "Using a Mac with an Apple Silicon chip (M1/M2/M3/…)?"
    Almost everything works, but the AprilTag features (drone tracking and `type = apriltag` calibrations) currently don't run natively on Apple Silicon. If you need those, install the **Intel (x86_64) Julia binary** and run it under Rosetta 2. Everything else — checkerboard calibrations and ordinary fixed-camera tracking — works natively. Details on the [Help page](help.md#Macs).

## 2. Install Fromage

Open Julia, type `]` to enter the package manager (the prompt changes to `pkg>`), and run:

```
pkg> add https://github.com/yakir12/Fromage.jl
```

That's it — this installs Fromage and everything it needs. Press backspace to leave the package manager.

## 3. Run your first analysis

### Prepare a folder

Put your video files together with two small spreadsheet files, `calibs.csv` and `runs.csv`, in one folder:

```
my experiment/
├── calibs.csv        ← one row per calibration video
├── runs.csv          ← one row per run video
├── calib_morning.mp4
├── beetle01.mp4
├── beetle02.mp4
└── ...
```

The two csv files are where you tell Fromage what to do — which video is which, when each run starts and stops, how big the target is, and so on. The [data folder page](data-folder.md) explains them, and template files to copy from live in [`examples/`](https://github.com/yakir12/Fromage.jl/tree/main/examples).

### Start Julia with multiple threads

Tracking and calibrating are parallelized, and this makes a big difference. In your terminal:

```sh
julia --threads=auto
```

### Run it

```julia
using Fromage
runs = main("the/path/to/your/data/folder")
```

`main` then works through four stages:

1. **Checks everything first.** Every row of both csv files is validated: files exist and are readable videos, timestamps fall within each video's duration, the checkerboard is actually detectable, all parameters are within sane ranges. If *anything* is wrong, it prints one line per problematic row (e.g. `row 3: file does not exist, wrong start format`) and stops before any tracking starts — fix the csv files and run again. Nothing is half-done.
2. **Builds a calibration** for every run from its entry in `calibs.csv`.
3. **Tracks the target** in every run.
4. **Writes your results**: one track file per run plus a single diagnostic video, all in a `results_dir` folder (created where you started Julia).

### Watch the diagnostic video

Open `results_dir/diagnostic.mp4` and watch it — it shows every run with a circle around the tracked position and a trailing trace. This is the fastest way to catch a tracker that latched onto a shadow or a wrong starting position. **Always watch it before using the tracks.**

## Where to next?

- [The data folder](data-folder.md) — how to organise your files and the rules both csv files share.
- [runs.csv](runs.md) — describing your run videos.
- [calibs.csv](calibs.md) — describing your calibration videos.
- [Your results](results.md) — what the output files contain and how the coordinates work.
- [Help & troubleshooting](help.md) — when something goes wrong.
