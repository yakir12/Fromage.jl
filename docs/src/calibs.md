# calibs.csv — your calibration videos

`calibs.csv` describes your **calibrations**: how Fromage converts pixels in each camera view into real-world coordinates on the arena floor. One row per calibration. Every run in `runs.csv` points at one of these rows through its `calibration_id`.

Not sure about the general formatting rules (timestamps, coordinates, blank cells)? See [the data folder](data-folder.md#Rules-both-csv-files-share) first.

## The four kinds of calibration

Every calibration is anchored to a video file of the arena. There are four kinds, selected with the `type` column:

- **`checkerboard`** (the default): a video of a checkerboard being moved around the arena, then laid flat on the arena floor. Yields a full calibration — lens distortion, perspective, and scale. **This is the one you'll usually want.**
- **`uniform`**: no checkerboard; you supply the real-world width of one pixel and nothing is measured from the video. The result is a single uniform scaling, so there is **no distortion and no perspective correction at all** — only appropriate for a distortion-free lens pointed straight down at the arena. If your camera is at an angle, or your lens bends straight lines, use `checkerboard` instead.
- **`matlab`**: a calibration you already made with MATLAB's Camera Calibrator app, supplied as a `.mat` file. The camera model — intrinsics, lens distortion, and the extrinsic poses — is read from the file instead of being fit from a video.
- **`apriltag`**: drone (moving-camera) footage with four (or more) coplanar AprilTags visible on the arena floor. Instead of a fixed image→arena map, every run frame is registered to a shared reference — built from the `extrinsic` frame — so the drone's motion is cancelled and the target comes out in metric ground coordinates. The tags must stay in the same physical place across the calibration and all its runs.

## What makes a good calibration video

For the usual `checkerboard` type:

- Film the checkerboard at the same location and with the exact same camera settings (zoom, resolution, mounting) as the runs it will calibrate.
- During [`intrinsic_start`, `intrinsic_stop`], move and tilt the board through the volume where the animal will be — variety of poses is what constrains the lens model.
- Then lay the board flat on the arena floor and note that timestamp — that's your `extrinsic`.
- Keep the full board visible and unobstructed; avoid motion blur (move slowly) and glare.

## Columns for `type = checkerboard`

Required:

| column | description |
| --- | --- |
| `calibration_id` | a unique name for this calibration; referenced from `runs.csv`. It also names this calibration's rectification image, so it has to be usable as a file name — see the note below. |
| `file` | the video file name, including extension. |
| `extrinsic` | timestamp of a frame where the checkerboard lies **flat on the arena floor**. This frame anchors the mapping between the image and the arena surface, so make sure the full board is clearly visible in it. |

!!! note "`calibration_id` becomes a file name"
    With `rectification_diagnostics = true` each calibration's [rectification image](results.md#The-rectification-images) is saved as `<calibration_id>.jpg`, so the id may not contain `/`, `\`, `:`, `*`, `?`, `"`, `<`, `>` or `|`, and may not be `.` or `..`. A bad one is reported along with everything else in the file, before any calibration is built. Spaces and apostrophes are fine.

Optional:

| column | default | description |
| --- | --- | --- |
| `intrinsic_start`, `intrinsic_stop` | — | **the intrinsic window**: the time window during which the checkerboard is being moved around (tilted, shifted) to fit the lens model. Provide both or neither. The window must be long enough to contain at least 3 sampled frames with a detectable checkerboard (see `temporal_step`). When **both** are omitted the calibration is fit from the single `extrinsic` frame alone, and lens distortion is disregarded — only appropriate for distortion-free lenses; otherwise film a calibration window and provide it. |
| `checker_width` | `4` | side length of a single checker square, in the real-world unit of your choice (e.g. cm). **The resulting track coordinates come out in this unit.** |
| `n_corners` | `"(7, 10)"` | number of *internal* corners of the checkerboard along its two sides (a board of 8 × 11 squares has 7 × 10 internal corners); each must be at least 2. |
| `temporal_step` | `2.0` | sample one frame every `temporal_step` seconds within the intrinsic window. E.g. a 30-second window at the default yields 16 candidate frames. Ignored without a calibration window. |
| `center` | — | `"(x, y)"` pixel coordinate of the arena's center, **as the video is displayed** (the same convention as `start_location` in `runs.csv`: for anamorphic footage, x is measured across the displayed width, not the stored one). Becomes the **origin** of the real-world coordinate system, and doubles as the default starting location for this calibration's runs. |
| `north` | — | `"(x, y)"` pixel coordinate of a point lying due north of `center`, in the same displayed-pixel convention. Rotates the real-world coordinates so that north is consistent across calibrations. Requires `center`. |
| `blur` | `1` | Gaussian blur (sigma, in pixels) applied to frames before corner detection; helps with noisy/sharpened footage. `0` disables. |
| `radial_parameters` | `1` | number of radial lens-distortion coefficients to fit (1–3). More isn't automatically better — use 2–3 only for strongly distorting (e.g. fisheye) lenses. Ignored without a calibration window. |
| `path` | `.` | the **folder** containing `file`, relative to the location of the csv file. Just the folder — the file name belongs in `file`, not here. |
| `aspect` | read from video | pixel aspect ratio; only override for anamorphic footage that misreports it. |
| `yadif` | read from video | `true` to deinterlace interlaced footage; detected automatically, override to force. |
| `type` | `checkerboard` | see above. |

!!! warning "Renamed in v0.1.58"
    `checker_width` used to be called `checker_size`. That name also served `type = apriltag` rows, where it meant a different quantity — a tag cell rather than a checkerboard square — so it has split in two: checkerboard rows use `checker_width`, apriltag rows use [`tag_cell_width`](#Columns-for-type-apriltag). A csv that still names `checker_size` is rejected up front with `unrecognized column/s in calibration file: [:checker_size]` and a note naming both replacements; rename the column and the file loads exactly as before. Nothing about the calibration changes.

!!! warning "Renamed in v0.2.23"
    Four names in this file changed, all so that each one says what it means. Every replacement is a plain find-and-replace in your spreadsheet; nothing about any calibration changes.

    | was | is now | why |
    | --- | --- | --- |
    | `type = video` | `type = checkerboard` | *every* kind here is anchored to a video — `apriltag` and `matlab` included — so `video` distinguished nothing. The checkerboard is what makes this one particular. |
    | `type = only_scale` | `type = uniform` | its `scale` column became `pixel_width`, leaving the type named after a word no longer in the file. |
    | `scale` | `pixel_width` | `runs.csv` also has a `scale`, meaning something unrelated (a downsampling factor, now `downscale`). `pixel_width` also matches how `checker_width` and `tag_cell_width` are named: the real-world width of the thing that sets your unit. |
    | `start`, `stop` | `intrinsic_start`, `intrinsic_stop` | `runs.csv` uses `start`/`stop` for the span of a run to *track*, which is a different thing from the window in which you wave the board. |

    An old column name is rejected up front, naming its replacement — e.g. `unrecognized column/s in calibration file: [:scale] (scale was renamed to pixel_width (and type = only_scale is now type = uniform))`. An old `type` value is reported per row, as `wrong type (video was renamed to checkerboard)`. Rows that left `type` blank are unaffected: the default was `video` and is now `checkerboard`, which is the same kind of calibration.

!!! tip "Count the *internal* corners"
    `n_corners` counts where four squares meet, not the squares themselves. A board of 8 × 11 squares has 7 × 10 internal corners.

## Columns for `type = uniform`

Required: `calibration_id`, `file`, `extrinsic` (a timestamp of any representative frame), and:

| column | description |
| --- | --- |
| `pixel_width` | the real-world width of one displayed pixel (e.g. cm/pixel). **The resulting track coordinates come out in this unit.** |

Optional: `path`, `center`, `north`, `aspect` — same meaning as above.

## Columns for `type = matlab`

Required: `calibration_id`, `file` (a video of the arena from the same camera — its frame size is cross-checked against the `.mat`'s `ImageSize`), `extrinsic` (a timestamp of any representative frame, used for the diagnostics), and:

| column | description |
| --- | --- |
| `matlab_file` | the `.mat` file exported by MATLAB's Camera Calibrator (must contain `K`, `RotationVectors`, `TranslationVectors`, `RadialDistortion`, and `ImageSize`; a nested `cameraParams` struct is handled). |
| `extrinsic_index` | 1-based index of the calibration image whose pose anchors the image ↔ arena mapping — pick the one where the board lies flat on the arena floor. |

Optional: `path`, `center`, `north`, `aspect` — same meaning as above. Real-world coordinates come out in whatever world units the MATLAB calibration was given (its square size).

## Columns for `type = apriltag`

Required: `calibration_id`, `file` (the drone footage — a video where the tags are visible), `extrinsic` (a timestamp of the frame that establishes the shared reference: **all** the tags must be clearly visible and lie flat on the arena floor there). Optional:

| column | default | description |
| --- | --- | --- |
| `apriltags` | `4` | how many tags to expect. The `apriltags` lowest tag ids seen at `extrinsic` become the reference set; every run must show those same tags. |
| `family` | `tag36h11` | the AprilTag family; one of `tag36h11`, `tag25h9`, `tag16h5`. |
| `tag_cell_width` | `12` | the real-world size of a single tag **cell** (e.g. cm). The black-border square is `cells × tag_cell_width`, where `cells` is 8 for `tag36h11`, 7 for `tag25h9`, 6 for `tag16h5`. **Track coordinates come out in this unit.** |
| `center` | — | `"(x, y)"` pixel of the arena's origin **in the `extrinsic` frame**, as displayed. Becomes the origin of the real-world coordinates. |
| `north` | — | `"(x, y)"` pixel due north of `center` in the `extrinsic` frame, as displayed; rotates the coordinates so north is consistent, and orients the [diagnostic video](results.md#The-diagnostic-video) the same way. Worth setting whenever you want to compare two calibrations of one arena: without it, the orientation follows whichever tag board carries the lowest id. Requires `center`. |
| `path` | `.` | the **folder** containing `file`, relative to the csv file. Just the folder — the file name belongs in `file`, not here. |

!!! warning "Renamed in v0.1.58"
    This column used to be called `checker_size`, a name it shared with the checkerboard square size of `type = checkerboard` rows. The two are different quantities, and one column could not carry both defaults — a global `checker_size` applied to checkerboard rows and silently did nothing to apriltag ones. The column has therefore split in two: checkerboard rows now use [`checker_width`](#Columns-for-type-checkerboard), apriltag rows use `tag_cell_width`. If you have already renamed it to `checker_width` but left it filled on an apriltag row, that is reported as `checker_width is not used by type apriltag (it was renamed to tag_cell_width)`.

The tags are stationary across the whole experiment, so the reference is established once here and shared by every run — `runs.csv` therefore has no `apriltags` column (and, for an apriltag run, a run's own `start` frame is where its target search begins, not the calibration's `center`).

!!! warning "AprilTags on Apple Silicon Macs"
    `type = apriltag` calibrations currently don't run natively on Apple Silicon (M1/M2/M3/…) Macs — see [the Help page](help.md#Macs) for the workaround.

## Mixing kinds in one file

All kinds can be mixed in one file — leave a column blank on the rows where it doesn't apply:

```csv
calibration_id,type,file,extrinsic,intrinsic_start,intrinsic_stop,checker_width,n_corners,center,north,pixel_width,apriltags,family,tag_cell_width
morning,checkerboard,calib_morning.mp4,00:00:02,00:00:05,00:00:35,4,"(7, 10)","(960, 540)","(960, 100)",,,,
afternoon,,calib_afternoon.mp4,1.5,5,35,4,"(7, 10)","(955, 545)",,,,,
drone,uniform,drone_shot.mp4,0,,,,,"(2000, 1500)",,0.21,,,
flight,apriltag,drone_flight.mp4,00:00:04,,,,,"(960, 540)","(960, 100)",,4,tag36h11,12
```

## Next

- [Your results →](results.md)
