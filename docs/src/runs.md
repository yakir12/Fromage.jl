# runs.csv — your run videos

`runs.csv` describes your **runs**: the videos of an animal (or any other target) moving through the arena. One row per run video. (A run split across multiple video files uses several rows — see [Runs that span multiple videos](#Runs-that-span-multiple-videos) below.)

Not sure about the general formatting rules (timestamps, coordinates, blank cells)? See [the data folder](data-folder.md#Rules-both-csv-files-share) first.

## Required columns

Only two columns must always be there:

| column | description |
| --- | --- |
| `file` | the video file name, including its extension (e.g. `beetle01.mp4`). |
| `calibration_id` | which calibration to use for this run — must match a `calibration_id` in `calibs.csv`. |

A minimal `runs.csv` can be just:

```csv
file,calibration_id
beetle01.mp4,morning
beetle02.mp4,morning
beetle03.mp4,afternoon
```

## Optional columns

| column | default | description |
| --- | --- | --- |
| `start` | `0` | timestamp where the run starts in the video. |
| `stop` | full duration | timestamp where the run ends. |
| `target_width` | `25` | the full width (diameter, not radius) of the target, in pixels. **The single most important tuning parameter** — measure it in a paused frame. |
| `start_location` | see [below](#Where-the-tracker-starts-looking) | `"(x, y)"` pixel coordinate of the target at `start`. |
| `darker_target` | `true` | `true` if the target is darker than its background, `false` if lighter. |
| `window_size` | computed | the size of the search window the tracker scans around the target's last known position: a single number for a square window (e.g. `41`) or `"(w, h)"` for a rectangle. Must be comfortably larger than `target_width` plus however far the target can move between consecutive frames. The default is computed from `target_width` and a conservative speed estimate, and is usually fine. |
| `native_fps` | what the video file reports | the frame rate the video itself runs at. You normally leave this blank — it is read from the file. Fill it in when the file is **wrong** about its own rate, and that is then the rate everything believes: the sampling stride, the timestamps in your track file, and the diagnostic video's playback speed. It cannot be higher than the rate the file reports (see the note below). |
| `sample_fps` | `native_fps` | how many frames per second to track. Lower it for slow targets to speed things up. Cannot exceed `native_fps`. Tracking advances whole frames, so the only rates available are `native_fps` divided by a whole number: ask for anything else and you get the nearest one (on 30 fps footage, `sample_fps = 20` tracks at 15, and `sample_fps = 25` at 30). The timestamps in your track file always describe the rate actually used, never the one requested. |
| `initial_search_factor` | `4` | when no start location is known at all, the target is searched for in a window of size `min(width, height) / initial_search_factor` centered on the frame. Larger values → smaller initial search window. |
| `scale` | `1` | spatial downsampling factor (0 < scale ≤ 1) applied before tracking; e.g. `0.5` tracks on half-resolution frames (faster). Returned coordinates are always in original-resolution pixels. The scaled target (`target_width × scale`) must remain at least 1 pixel wide. Lowering it costs precision: on clean footage the tracking error is a fraction of a percent of `target_width` down to about `0.25`, a few percent by `0.1`, and worse below that — so treat it as a speed knob for large frames, not a default to reduce. |
| `background_length` | `250` | how many tracked frames form the rolling background model the target is detected against. Counted at the sampling rate, so the model spans `background_length / sample_fps` seconds; memory scales with it. `0` disables background subtraction entirely — fine for clean, high-contrast scenes (and much lighter on memory), but static dark marks then compete with the target. Must be `0` or at least `25`. |
| `run_id` | row number | identifies the run; only needed for multi-video runs (below). All-or-nothing: either every row has a `run_id`, or none does. It also names your track file, so it has to be usable as one — see below. |
| `path` | `.` | the **folder** containing `file`, relative to the location of the csv file. Just the folder — the file name belongs in `file`, not here. |
| `comment` | — | free text, ignored. |

!!! note
    AprilTag drone tracking is configured entirely from `calibs.csv` — see [`type = apriltag`](calibs.md#Columns-for-type-apriltag) — so `runs.csv` has no `apriltags` column.

!!! warning "Renamed in v0.2.0"
    The `fps` column has been **split in two**. It used to mean both "the rate this video runs at" and "the rate to track it at" — the same number by default, and impossible to separate when they differed. Track at a lower rate with [`sample_fps`](#Optional-columns), which is what a plain `fps` always meant; use [`native_fps`](#Optional-columns) to correct a video that misreports its own rate. A csv that still names `fps` is rejected up front with `unrecognized column/s in runs file: [:fps] (fps was renamed to sample_fps — the video's own rate is native_fps)`. Renaming the column to `sample_fps` reproduces exactly what you had.

!!! note "Why `native_fps` cannot be raised"
    `start` and `stop` stay in the video file's own seconds no matter what you declare, so claiming a rate *higher* than the file reports claims that your window holds more frames than it does — and the tracker would run off the end of the video partway through the run. A file that overstates its rate is the case worth correcting; one that understates it cannot be expressed here, because the frames it would need are not in the file.

!!! warning "Removed in v0.1.19"
    The `white_point` column was accepted but never had any effect, so it has been removed. A `runs.csv` that still has the column is now rejected with `unrecognized column/s in runs file: [:white_point]` — delete the column and the file loads as before. Nothing about tracking changes, since the value was never read.

!!! tip "The one parameter worth measuring: `target_width`"
    Pause a run video on a frame where the animal is clearly visible, and measure how many pixels wide it is (many image viewers let you draw a selection box and read off its size). If the tracker keeps losing your animal, a wrong `target_width` is the first thing to check.

## Where the tracker starts looking

The starting position for a run is determined by the first available of:

1. `start_location` in `runs.csv`,
2. the `center` of the run's calibration in `calibs.csv`,
3. nothing — the target is searched for near the center of the frame, within a window of `min(width, height) / initial_search_factor` pixels.

## Runs that span multiple videos

If a single run was recorded across several consecutive video files (e.g. the camera splits long recordings), give all its rows the **same `run_id`**, one row per video file, in chronological order:

```csv
run_id,calibration_id,file,start,stop,start_location
long,afternoon,beetle03_a.mp4,0,,"(210, 400)"
long,afternoon,beetle03_b.mp4,0,00:01:03,
```

- `file`, `start`, `stop`, and `start_location` are per segment; all other parameters (`target_width`, `sample_fps`, `calibration_id`, …) must be identical across the segments of one run, and all segments must come from the same camera setup (same frame size).
- The segments are assumed to have been **filmed at the same frame rate** — they are pieces of one continuous recording, so normally they are. Footage that genuinely mixes frame rates is outside what Fromage tracks: a run has one timeline, and every timestamp in its track file is spaced at one rate. Left blank, the rate is read from each video and the segments must agree on it, so mismatched footage is reported rather than silently mistimed.
- A `native_fps` written on **any** row of a run is a statement about the whole recording, and applies to every one of its segments — so you write it once, on whichever row is convenient, and leave it blank on the rest. Two rows claiming *different* native rates cannot both be true and are rejected.
- Leave `start_location` blank on the second segment onwards: tracking continues from where the previous segment ended.
- `run_id` is all-or-nothing: as soon as one row has a `run_id`, every row needs one (rows with a `run_id` all of their own are ordinary single-video runs). If no row has one, each row is its own run.
- `run_id` becomes a **file name**: your track file is `<run_id>.csv`, and the diagnostic video is assembled from per-run parts named the same way. So it may not contain `/`, `\`, `:`, `*`, `?`, `"`, `<`, `>` or `|`, and may not be `.` or `..` — a bad one is reported along with everything else in the file, before any tracking starts. Spaces and apostrophes are fine (`beetle's run 3` works).

## Next

- [calibs.csv →](calibs.md)
- [Your results →](results.md)
