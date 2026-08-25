# Your results

When `main` finishes, you have two kinds of output: **files on disk** (in a `results_dir` folder, created in the folder Julia was started in) and, if you're working in Julia, a **DataFrame** returned by `main`. Most people only need the files.

## The track files

Each run's track is written to `results_dir/<run_id>.csv` — a plain csv you can open in Excel, R, Python, MATLAB, or anything else. It has three columns:

| column | content |
| --- | --- |
| `time` | the timestamp, in seconds into the video, of each detected coordinate. |
| `x`, `y` | the target's **real-world** coordinates at that time. |

The coordinates are already fully converted — lens distortion, perspective, and scale are all corrected:

- The **origin** (0, 0) is at the calibration's `center` (if you gave one).
- If you gave a `north` point, the coordinates are rotated so north is consistent across calibrations.
- The **unit** is whatever your calibration used: the `checker_width` unit for checkerboard calibrations (e.g. cm if you measured your squares in cm), the `tag_cell_width` unit for AprilTag ones, the `scale` unit for `only_scale`, or the MATLAB calibration's unit for `matlab`.
- `x` grows rightward and `y` grows **downward** in the image, like the pixel convention.

## The diagnostic video

`main` also writes `results_dir/diagnostic.mp4`: every run rendered top-down through its calibration into a fixed 540×540 canvas, with a circle around the tracked position, a trailing trace, and the run's `run_id` as a label — one run after the other, playing at 2× real time (≈24 fps regardless of the run's `sample_fps`).

This is what a healthy run looks like — the circle sits on the animal for the whole run, and the trace grows behind it from the centre of the arena to the edge (one complete run, looping):

![A complete run from the diagnostic video, looping: the arena viewed top-down, with a white circle following the tracked beetle while the trailing trace grows from the centre to the edge](assets/tracking-run.webp)

And the same check works in harder conditions. Here the arena is covered in dappled light, yet the circle should still follow the animal — if it jumps to a bright patch instead, you've caught a bad track:

![A frame of the diagnostic video under dappled forest light: despite the high-contrast light patches, the white circle still sits on the tracked beetle](assets/diagnostic-dappled.png)

!!! danger "Watch it!"
    The diagnostic video is the fastest way to catch a tracker that latched onto a shadow, a wrong starting position, or a bad calibration. Watch it before analysing any tracks.

Things to look for:

- The circle should stay on your animal for the whole run — not jump to a shadow, a droppings mark, or a cable.
- The arena should look right in the top-down view: straight edges straight, circles circular. A warped arena means a bad calibration.
- The trace should look like a plausible path for your animal.

## The rectification images

Off by default. Ask for them and `main` saves, for every calibration, that calibration's `extrinsic` frame warped through the rectification fit to it:

```julia
main("path/to/data"; rectification_diagnostics = true)
```

One JPEG per calibration lands in `results_dir/rectifications/`, named by its `calibration_id` — so `c1.jpg` is the calibration the csv calls `c1`. `only_rectify` takes the same keyword.

This is the same "is the arena square?" check the diagnostic video gives you, except you get it as soon as the calibrations are built, before a single run has been tracked. Straight arena edges should come out straight and circles circular. A bowed, sheared or wildly stretched image means the calibration is wrong, and there is no point tracking anything against it — fix the calibration first.

!!! note "AprilTag calibrations produce no image here"
    An `apriltag` calibration has no single fixed image-to-real map to warp through, because the drone moves and every frame is registered separately. Its top-down view is the per-run [diagnostic video](#The-diagnostic-video) instead.

## The issues folder

If a calibration fails detection — the checkerboard or the AprilTags can't be found in its extrinsic frame — Fromage saves that exact frame so you can see what it saw. The message in the report tells you where it went, e.g.:

```
row 2 (calibration_id: morning): only 4 of 6 AprilTags detected at the extrinsic frame — saved the extrinsic frame to results_dir/issues/2026-08-20T14-22-05/board_t1.0s.png for inspection
```

Each run gets its own time-stamped folder under `results_dir/issues`, named for the moment it started, so the folder holds exactly the frames of that run and older runs stay where they are. Nothing here is ever deleted: the folder is yours to clean out whenever you like.

Open the frame and look at it — a blurry, over-exposed, or half-out-of-shot board is usually the whole story, and the fix is a different `extrinsic` timestamp or a better calibration video.

## Working with the results in Julia

`main` returns a `DataFrame` with one row per run:

| column | content |
| --- | --- |
| `run_id`, `calibration_id` | the identifiers from the csv files. |
| `run` | the track: a tuple `(ts, coords)` of timestamps (seconds into the video) and the target's **real-world** coordinates — the same data as the track file. |
| `rectification` | the calibration: a named tuple whose `image2real` function converts pixel coordinates to real-world coordinates; `real2image` is its inverse. |
| `r`, `c` | the parsed run and calibration entries (all the resolved parameter values). |

For example:

```julia
runs = main("path/to/data")
ts, xy = runs.run[1]    # first run: timestamps + real-world coordinates (e.g. cm)
```
