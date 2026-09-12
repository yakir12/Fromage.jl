# Help & troubleshooting

## "It printed errors and stopped"

That's Fromage doing its job. Before anything is tracked, every row of both csv files is checked, and **all** problems are reported at once, one line per problematic row, e.g.:

```
row 3: file does not exist, wrong start format
```

The row's name is included too, so you can tell at a glance which entry needs fixing: issues with `rectifications.csv` show the row's `rectification_id` — e.g. `row 2 (rectification_id: morning): …` — and, if you gave your runs names (a `run_id` column in `runs.csv`), issues with runs show the `run_id` — e.g. `row 3 (run_id: beetle12): …`.

Nothing runs until they're all fixed — so nothing is ever half-done. Fix the mentioned rows in your csv files and run `main` again.

Among the things checked:

- all referenced files and folders exist, and the videos are actually readable;
- timestamps are well-formatted, non-negative, ordered (`start` < `stop`), and within the video's duration;
- pixel coordinates lie inside the frame;
- numeric parameters are within their valid ranges;
- `rectification_id`s are unique, and no two rectifications are effectively identical duplicates;
- a filled cell in a column that the row's `type` doesn't use is flagged (it usually means the `type` itself is wrong);
- the checkerboard is detected at the `extrinsic` timestamp, and — when a rectification window is given — at least 3 sampled frames within the intrinsic window [`intrinsic_start`, `intrinsic_stop`] have a detectable board (this is the expensive part of validation — it reads real frames);
- for an `apriltag` rectification, at least `apriltags` tags of the chosen `family` are detected at the `extrinsic` frame and their metric fit converges;
- segments of a multi-segment run agree on all their shared parameters;
- segments of one run cut from the **same** video file are in order and do not overlap — each one's `start` at or after the previous one's `stop` (segments in *different* files cannot be compared, so their order is yours to get right);
- every `rectification_id` used in `runs.csv` exists in `rectifications.csv`.

## "The tracker followed the wrong thing"

You saw it in the [diagnostic video](results.md#The-diagnostic-video) — good, that's what it's for. In rough order of likelihood:

1. **Wrong `target_width`.** Pause the run video, measure how many pixels wide the animal is, and put that in the `target_width` column. This is the single most important tracking parameter.
2. **Wrong starting position.** Give the run an explicit `start_location` (see [where the tracker starts looking](runs.md#Where-the-tracker-starts-looking)).
3. **Wrong contrast direction.** If your target is *lighter* than the background, set `darker_target` to `false`.
4. **The animal moves fast between frames.** Increase `window_size`, or track at the video's full frame rate (don't lower `sample_fps`).

## Iterating faster: run only part of the pipeline

While you're getting the csv files right, you don't have to run everything every time.

To check both csv files without processing anything, use `verify`:

```julia
out = Fromage.verify("path/to/data")
out.rectifications      # rectifications.csv, annotated with an `issues` column
out.runs        # runs.csv, likewise
```

It reports everything wrong with both files in one pass and never throws, so you can fix a whole
dataset in one sitting rather than one error per run. Both tables come back whether or not anything
was wrong — a dataset is accepted or rejected as a whole — so `all(isempty, out.rectifications.issues)` is
the question to ask. Nothing is rectified or tracked. (`main` is the one that does the work; it
aborts on any issue.)

Two more helpers run only one half of the pipeline (both still run the full validation of their csv file):

```julia
# only build rectifications (all of them, or a subset of rectification_ids):
Fromage.only_rectify("path/to/data"; rectifications_file = "rectifications.csv", rectification_ids = ["morning"])

# only track (no rectification involved), optionally a subset of run_ids;
# writes one raw-view diagnostic per run: results_dir/1.mp4, 2.mp4, ...
Fromage.only_track("path/to/data"; runs_file = "runs.csv", run_ids = ["run1", "long"])
```

`main` itself also accepts `run_ids` to process only a subset of the runs (only the rectifications those runs reference are built). Every id you list must exist: if even one does not, the run stops with an error naming it and listing the ids that do exist, rather than quietly processing the ones that matched.

`main` and `only_rectify` also accept `rectification_diagnostics = true`, which saves each rectification's warped extrinsic frame to `results_dir/rectifications/` so you can check a rectification before tracking against it — see [the rectification images](results.md#The-rectification-images).

## Re-running in the same Julia session

Fixing a csv file usually takes a few passes: run `main`, read what it says, edit a row, run it
again. Only the first pass pays for the reading. Everything Fromage reads or detects while checking
your files — one `ffprobe` per video, one read per MATLAB calibration file, the checkerboard or
AprilTag detection at each rectification's `extrinsic` timestamp, and the scan of each intrinsic
window — is remembered for as long as that Julia session is alive, so the rows you did not touch
cost nothing the second time. Edit a row and only what that row changed is re-read.

This matters most where it hurts most: on a network share, reading a video is the slow part of
checking a dataset, and a second run over a 300-run folder used to cost the same as the first.

There is one assumption in it, and it is worth knowing:

!!! warning "A file is remembered by its name, not by its contents"
    Fromage never re-checks a file it has already read. If you **replace a video or a `.mat` file in
    place** — re-copying a corrupt recording, re-exporting a calibration — while Julia is still
    running, Fromage will keep reporting what the old file said. So will `Revise.jl` users who
    change Fromage itself mid-session.

    Two ways out, either is fine:

    ```julia
    Fromage.empty_caches!()   # forget everything read so far; the next run reads it all again
    ```

    or simply quit Julia and start again. Renaming the new file instead of overwriting the old one
    also works, since the name is what is remembered.

What is remembered is what Fromage *found* — the video's size and duration, whether the board was
detectable. A file it could **not read at all** is never remembered, so a network hiccup on the share
does not become permanent: run it again and that file is read again.

Nothing else is affected either: the report you get is exactly the report you would have got from a
cold start, and the [issues folder](results.md#The-issues-folder) still gets a fresh, time-stamped
folder on every run.

## Changing a default for all rows at once

The default of every *tuning* column can be overridden globally from `main`, so you don't have to fill in the same value on every row. The hierarchy is: a csv cell always wins over a global default, which wins over the built-in default (including the value probed from the video, for `yadif` and `native_fps`):

```julia
main("path/to/data";
     rectification_defaults = (n_corners = (5, 8), blur = 0),
     tracking_defaults      = (target_width = 60, sample_fps = 25))
```

- `rectification_defaults` may set: `checker_width`, `n_corners`, `temporal_step`, `radial_parameters`, `blur`, `yadif`, and — for `type = apriltag` rows — `apriltags`, `family`, `tag_cell_width`.
- `tracking_defaults` may set: `target_width`, `window_size`, `darker_target`, `native_fps`, `sample_fps`, `initial_search_factor`, `downscale`, `background_length`.

Anything else (identities, file names, timestamps, `start_location`/`center`/`north`) is per-row only, and an unrecognized or unconvertible entry is rejected with an error before anything runs. Global values pass through the same validation as csv cells — e.g. a global `sample_fps` must still not exceed each run's `native_fps`. `only_rectify` and `only_track` accept their respective keyword (`rectification_defaults` / `tracking_defaults`).

## Macs

What matters is the CPU, not the macOS version (as of July 2026):

- **Intel Macs** (`x86_64`): everything works — the full test suite runs on every commit on an Intel macOS runner.
- **Apple Silicon Macs** (M1/M2/M3/…, `aarch64`) running the native arm64 Julia: everything works **except the AprilTag functionality** — `type = apriltag` rectifications and drone tracking fail with `UndefVarError: libapriltag not defined`. The cause is upstream: `AprilTags_jll` ships no `aarch64-apple-darwin` binaries, so the AprilTag C library can never load. `checkerboard`, `uniform`, and `matlab` rectifications, and all tracking of ordinary (fixed-camera) runs, are unaffected.
- **Workaround on Apple Silicon**: install the **Intel (x86_64) Julia binary** and run it under Rosetta 2 — Julia then pulls the `x86_64-apple-darwin` artifacts for all binary dependencies, AprilTags included. Slower, but functional.

Linux and Windows (x64) are fully tested in CI.

## Still stuck?

Ask in the lab, or [open an issue on GitHub](https://github.com/yakir12/Fromage.jl/issues) — include the exact error message and, if possible, the csv row that triggers it.
