# Help & troubleshooting

## "It printed errors and stopped"

That's Fromage doing its job. Before anything is tracked, every row of both csv files is checked, and **all** problems are reported at once, one line per problematic row, e.g.:

```
row 3: file does not exist, wrong start format
```

Nothing runs until they're all fixed — so nothing is ever half-done. Fix the mentioned rows in your csv files and run `main` again.

Among the things checked:

- all referenced files and folders exist, and the videos are actually readable;
- timestamps are well-formatted, non-negative, ordered (`start` < `stop`), and within the video's duration;
- pixel coordinates lie inside the frame;
- numeric parameters are within their valid ranges;
- `calibration_id`s are unique, and no two calibrations are effectively identical duplicates;
- a filled cell in a column that the row's `type` doesn't use is flagged (it usually means the `type` itself is wrong);
- the checkerboard is detected at the `extrinsic` timestamp, and — when a calibration window is given — at least 3 sampled frames within [`start`, `stop`] have a detectable board (this is the expensive part of validation — it reads real frames);
- for an `apriltag` calibration, at least `apriltags` tags of the chosen `family` are detected at the `extrinsic` frame and their metric fit converges;
- segments of a multi-video run agree on all their shared parameters;
- every `calibration_id` used in `runs.csv` exists in `calibs.csv`.

## "The tracker followed the wrong thing"

You saw it in the [diagnostic video](results.md#The-diagnostic-video) — good, that's what it's for. In rough order of likelihood:

1. **Wrong `target_width`.** Pause the run video, measure how many pixels wide the animal is, and put that in the `target_width` column. This is the single most important tuning parameter.
2. **Wrong starting position.** Give the run an explicit `start_location` (see [where the tracker starts looking](runs.md#Where-the-tracker-starts-looking)).
3. **Wrong contrast direction.** If your target is *lighter* than the background, set `darker_target` to `false`.
4. **The animal moves fast between frames.** Increase `window_size`, or track at the video's full frame rate (don't lower `fps`).

## Iterating faster: run only part of the pipeline

While you're getting the csv files right, you don't have to run everything every time. Two helpers run only one half of the pipeline (both still run the full validation of their csv file):

```julia
# only build calibrations (all of them, or a subset of calibration_ids):
Fromage.only_rectify("path/to/data"; calibs_file = "calibs.csv", calibration_ids = ["morning"])

# only track (no calibration involved), optionally a subset of run_ids;
# writes one raw-view diagnostic per run: results_dir/1.mp4, 2.mp4, ...
Fromage.only_track("path/to/data"; runs_file = "runs.csv", run_ids = ["run1", "long"])
```

`main` itself also accepts `run_ids` to process only a subset of the runs (only the calibrations those runs reference are built).

## Changing a default for all rows at once

The default of every *tuning* column can be overridden globally from `main`, so you don't have to fill in the same value on every row. The hierarchy is: a csv cell always wins over a global default, which wins over the built-in default (including the value probed from the video, for `yadif` and `fps`):

```julia
main("path/to/data";
     rectification_defaults = (n_corners = (5, 8), blur = 0),
     tracking_defaults      = (target_width = 60, fps = 25))
```

- `rectification_defaults` may set: `checker_size`, `n_corners`, `temporal_step`, `radial_parameters`, `blur`, `yadif`.
- `tracking_defaults` may set: `target_width`, `window_size`, `darker_target`, `fps`, `initial_search_factor`, `white_point`, `scale`.

Anything else (identities, file names, timestamps, `start_location`/`center`/`north`) is per-row only, and an unrecognized or unconvertible entry is rejected with an error before anything runs. Global values pass through the same validation as csv cells — e.g. a global `fps` must still not exceed each video's own frame rate. `only_rectify` and `only_track` accept their respective keyword (`rectification_defaults` / `tracking_defaults`).

## Macs

What matters is the CPU, not the macOS version (as of July 2026):

- **Intel Macs** (`x86_64`): everything works — the full test suite runs on every commit on an Intel macOS runner.
- **Apple Silicon Macs** (M1/M2/M3/…, `aarch64`) running the native arm64 Julia: everything works **except the AprilTag functionality** — `type = apriltag` calibrations and drone tracking fail with `UndefVarError: libapriltag not defined`. The cause is upstream: `AprilTags_jll` ships no `aarch64-apple-darwin` binaries, so the AprilTag C library can never load. Checkerboard (`video`), `only_scale`, and `matlab` calibrations, and all tracking of ordinary (fixed-camera) runs, are unaffected.
- **Workaround on Apple Silicon**: install the **Intel (x86_64) Julia binary** and run it under Rosetta 2 — Julia then pulls the `x86_64-apple-darwin` artifacts for all binary dependencies, AprilTags included. Slower, but functional.

Linux and Windows (x64) are fully tested in CI.

## Still stuck?

Ask in the lab, or [open an issue on GitHub](https://github.com/yakir12/Fromage.jl/issues) — include the exact error message and, if possible, the csv row that triggers it.
