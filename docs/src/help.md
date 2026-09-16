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
- numeric parameters are finite (a `NaN` or `Inf` cell is rejected) and within their valid ranges;
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

## Iterating faster

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

`main` accepts `run_ids` to process only a subset of the runs (only the rectifications those runs reference are built):

```julia
main("path/to/data"; run_ids = ["run1", "long"])
```

Every id you list must exist: if even one does not, the run stops with an error naming it and listing the ids that do exist, rather than quietly processing the ones that matched.

### Checking the rectifications before anything is tracked

`main` builds every rectification before it tracks a single run. Ask it to save what each rectification looks like, and you can check them while it is still early:

```julia
main("path/to/data"; rectification_diagnostics = true)
```

Watch `results_dir/rectifications/`. One image per rectification appears there as soon as the rectifications are built — see [the rectification images](results.md#The-rectification-images) for what a good one looks like. If one is wrong, interrupt Julia (`Ctrl-C`), fix that row of `rectifications.csv`, and run `main` again. In the same Julia session the second run only rebuilds the rectification you changed (see [re-running in the same Julia session](#Re-running-in-the-same-Julia-session)), so checking this way costs little more than the rectification you fixed.

## Re-running in the same Julia session

Fixing a csv file usually takes a few passes: run `main`, read what it says, edit a row, run it
again. Only the first pass pays for the reading. Everything Fromage reads or detects while checking
your files — one `ffprobe` per video, one read per MATLAB calibration file, the checkerboard or
AprilTag detection at each rectification's `extrinsic` timestamp, and the scan of each intrinsic
window — is remembered for as long as that Julia session is alive, so the rows you did not touch
cost nothing the second time. Edit a row and only what that row changed is re-read.

The **built rectifications** are remembered too. Building one is the expensive half of a run: it
reads the source video again and detects the board or the tags in it, and a `checkerboard` with an
intrinsic window scans that whole window. A rectification is remembered by the *specification* it
was built from — the `rectifications.csv` row, together with the [global defaults](#Changing-a-default-for-all-rows-at-once)
its blank cells fall back on. So as long as you changed neither of those — and editing a `runs.csv`
row changes neither — the second `main` builds nothing at all and goes straight to tracking. Change
one rectification row, or a `rectification_defaults` value that row was leaning on, and only the
rectifications that actually changed are rebuilt.

So are the **tracks**, and tracking is by far the most expensive part of `main`. A run is remembered
by everything it is tracked with: its `runs.csv` rows, the [global defaults](#Changing-a-default-for-all-rows-at-once)
their blank cells fall back on, and the rectification it names. Watch the diagnostic video, fix one
run's row, run `main` again, and only that run is tracked again. Every other run's track, and its
piece of the diagnostic video, is reused — and every run still gets its `<run_id>.csv` and its place
in `diagnostic.mp4`, exactly as on the first pass. When anything was reused, `main` says how much:

```
[ Info: Reused 371 of 372 tracks from earlier in this session; Fromage.empty_caches!() forces a re-track
```

Renaming a run (its `run_id`) tracks it again, since the name is drawn on its part of the video.

This matters most where it hurts most: on a network share, reading a video is the slow part of
checking a dataset, and a second run over a 300-run folder used to cost the same as the first.

There is one assumption in it, and it is worth knowing:

!!! warning "A file is remembered by its name, not by its contents"
    Fromage never re-checks a file it has already read. If you **replace a video or a `.mat` file in
    place** — re-copying a corrupt recording, re-exporting a calibration — while Julia is still
    running, Fromage will keep reporting what the old file said, and will keep handing you the
    rectification it built, and the track it tracked, from the old one: both are remembered by the
    specification they came from, and that specification still names the same file. So will `Revise.jl` users who
    change Fromage itself mid-session.

    Two ways out, either is fine:

    ```julia
    Fromage.empty_caches!()   # forget everything read, built and tracked so far; the next run redoes it all
    ```

    or simply quit Julia and start again. Renaming the new file instead of overwriting the old one
    also works, since the name is what is remembered.

What is remembered is what Fromage *found* — the video's size and duration, whether the board was
detectable — and what it *built*. A file it could **not read at all** is never remembered, and
neither is a rectification that failed to build or a run that failed to track, so a network hiccup on the share does not become
permanent: run it again and that file is read again.

Nothing else is affected either: the report you get is exactly the report you would have got from a
cold start, the [issues folder](results.md#The-issues-folder) still gets a fresh, time-stamped
folder on every run, and `rectification_diagnostics = true` still writes every image on every run —
including for the rectifications it did not have to build again.

## Changing a default for all rows at once

The default of every *tuning* column can be overridden globally from `main`, so you don't have to fill in the same value on every row. The hierarchy is: a csv cell always wins over a global default, which wins over the built-in default (including the value probed from the video, for `yadif` and `native_fps`):

```julia
main("path/to/data";
     rectification_defaults = (n_corners = (5, 8), blur = 0),
     tracking_defaults      = (target_width = 60, sample_fps = 25))
```

- `rectification_defaults` may set: `checker_width`, `n_corners`, `temporal_step`, `radial_parameters`, `blur`, `yadif`, and — for `type = apriltag` rows — `apriltags`, `family`, `tag_cell_width`.
- `tracking_defaults` may set: `target_width`, `window_size`, `darker_target`, `native_fps`, `sample_fps`, `initial_search_factor`, `downscale`, `background_length`.

Anything else (identities, file names, timestamps, `start_location`/`center`/`north`) is per-row only, and an unrecognized, unconvertible or non-finite (`NaN`, `Inf`) entry is rejected with an error before anything runs. Global values pass through the same validation as csv cells — e.g. a global `sample_fps` must still not exceed each run's `native_fps`.

## Macs

What matters is the CPU, not the macOS version (as of July 2026):

- **Intel Macs** (`x86_64`): everything works — the full test suite runs on every commit on an Intel macOS runner.
- **Apple Silicon Macs** (M1/M2/M3/…, `aarch64`) running the native arm64 Julia: everything works **except the AprilTag functionality** — `type = apriltag` rectifications and drone tracking fail with `UndefVarError: libapriltag not defined`. The cause is upstream: `AprilTags_jll` ships no `aarch64-apple-darwin` binaries, so the AprilTag C library can never load. `checkerboard`, `uniform`, and `matlab` rectifications, and all tracking of ordinary (fixed-camera) runs, are unaffected.
- **Workaround on Apple Silicon**: install the **Intel (x86_64) Julia binary** and run it under Rosetta 2 — Julia then pulls the `x86_64-apple-darwin` artifacts for all binary dependencies, AprilTags included. Slower, but functional.

Linux and Windows (x64) are fully tested in CI.

## Still stuck?

Ask in the lab, or [open an issue on GitHub](https://github.com/yakir12/Fromage.jl/issues) — include the exact error message and, if possible, the csv row that triggers it.
