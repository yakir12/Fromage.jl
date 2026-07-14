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
| `fps` | video's frame rate | how many frames per second to track. Lower it for slow targets to speed things up. Cannot exceed the video's own frame rate. |
| `initial_search_factor` | `4` | when no start location is known at all, the target is searched for in a window of size `min(width, height) / initial_search_factor` centered on the frame. Larger values → smaller initial search window. |
| `scale` | `1` | spatial downsampling factor (0 < scale ≤ 1) applied before tracking; e.g. `0.5` tracks on half-resolution frames (faster). Returned coordinates are always in original-resolution pixels. The scaled target (`target_width × scale`) must remain at least 1 pixel wide. |
| `background_length` | `250` | how many tracked frames form the rolling background model the target is detected against. Counted at the tracking `fps`, so the model spans `background_length / fps` seconds; memory scales with it. `0` disables background subtraction entirely — fine for clean, high-contrast scenes (and much lighter on memory), but static dark marks then compete with the target. Must be `0` or at least `25`. |
| `run_id` | row number | identifies the run; only needed for multi-video runs (below). All-or-nothing: either every row has a `run_id`, or none does. |
| `path` | `.` | folder containing `file`, relative to the location of the csv file. |
| `comment` | — | free text, ignored. |

!!! note
    The `white_point` column is accepted for compatibility but currently has **no effect**. AprilTag drone tracking is configured entirely from `calibs.csv` — see [`type = apriltag`](calibs.md#Columns-for-type-apriltag) — so `runs.csv` has no `apriltags` column.

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

- `file`, `start`, `stop`, and `start_location` are per segment; all other parameters (`target_width`, `fps`, `calibration_id`, …) must be identical across the segments of one run, and all segments must come from the same camera setup (same frame size).
- Leave `start_location` blank on the second segment onwards: tracking continues from where the previous segment ended.
- `run_id` is all-or-nothing: as soon as one row has a `run_id`, every row needs one (rows with a `run_id` all of their own are ordinary single-video runs). If no row has one, each row is its own run.

## Next

- [calibs.csv →](calibs.md)
- [Your results →](results.md)
