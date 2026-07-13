# calibs.csv — your calibration videos

`calibs.csv` describes your **calibrations**: how Fromage converts pixels in each camera view into real-world coordinates on the arena floor. One row per calibration. Every run in `runs.csv` points at one of these rows through its `calibration_id`.

Not sure about the general formatting rules (timestamps, coordinates, blank cells)? See [the data folder](data-folder.md#Rules-both-csv-files-share) first.

## The four kinds of calibration

Every calibration is anchored to a video file of the arena. There are four kinds, selected with the `type` column:

- **`video`** (the default): a video of a checkerboard being moved around the arena, then laid flat on the arena floor. Yields a full calibration — lens distortion, perspective, and scale. **This is the one you'll usually want.**
- **`only_scale`**: no checkerboard; you supply a fixed scale (real-world units per pixel). No distortion or perspective correction — appropriate for e.g. distortion-free footage filmed straight down.
- **`matlab`**: a calibration you already made with MATLAB's Camera Calibrator app, supplied as a `.mat` file. The camera model — intrinsics, lens distortion, and the extrinsic poses — is read from the file instead of being fit from a video.
- **`apriltag`**: drone (moving-camera) footage with four (or more) coplanar AprilTags visible on the arena floor. Instead of a fixed image→arena map, every run frame is registered to a shared reference — built from the `extrinsic` frame — so the drone's motion is cancelled and the target comes out in metric ground coordinates. The tags must stay in the same physical place across the calibration and all its runs.

## What makes a good calibration video

For the usual `video` type:

- Film the checkerboard at the same location and with the exact same camera settings (zoom, resolution, mounting) as the runs it will calibrate.
- During [`start`, `stop`], move and tilt the board through the volume where the animal will be — variety of poses is what constrains the lens model.
- Then lay the board flat on the arena floor and note that timestamp — that's your `extrinsic`.
- Keep the full board visible and unobstructed; avoid motion blur (move slowly) and glare.

## Columns for `type = video`

Required:

| column | description |
| --- | --- |
| `calibration_id` | a unique name for this calibration; referenced from `runs.csv`. |
| `file` | the video file name, including extension. |
| `extrinsic` | timestamp of a frame where the checkerboard lies **flat on the arena floor**. This frame anchors the mapping between the image and the arena surface, so make sure the full board is clearly visible in it. |

Optional:

| column | default | description |
| --- | --- | --- |
| `start`, `stop` | — | the time window during which the checkerboard is being moved around (tilted, shifted) for the internal camera calibration. Provide both or neither. The window must be long enough to contain at least 3 sampled frames with a detectable checkerboard (see `temporal_step`). When **both** are omitted the calibration is fit from the single `extrinsic` frame alone, and lens distortion is disregarded — only appropriate for distortion-free lenses; otherwise film a calibration window and provide it. |
| `checker_size` | `4` | side length of a single checker square, in the real-world unit of your choice (e.g. cm). **The resulting track coordinates come out in this unit.** |
| `n_corners` | `"(7, 10)"` | number of *internal* corners of the checkerboard along its two sides (a board of 8 × 11 squares has 7 × 10 internal corners); each must be at least 2. |
| `temporal_step` | `2.0` | sample one frame every `temporal_step` seconds within [`start`, `stop`]. E.g. a 30-second window at the default yields 16 candidate frames. Ignored without a calibration window. |
| `center` | — | `"(x, y)"` pixel coordinate of the arena's center. Becomes the **origin** of the real-world coordinate system, and doubles as the default starting location for this calibration's runs. |
| `north` | — | `"(x, y)"` pixel coordinate of a point lying due north of `center`. Rotates the real-world coordinates so that north is consistent across calibrations. Requires `center`. |
| `blur` | `1` | Gaussian blur (sigma, in pixels) applied to frames before corner detection; helps with noisy/sharpened footage. `0` disables. |
| `radial_parameters` | `1` | number of radial lens-distortion coefficients to fit (1–3). More isn't automatically better — use 2–3 only for strongly distorting (e.g. fisheye) lenses. Ignored without a calibration window. |
| `path` | `.` | folder containing `file`, relative to the location of the csv file. |
| `aspect` | read from video | pixel aspect ratio; only override for anamorphic footage that misreports it. |
| `yadif` | read from video | `true` to deinterlace interlaced footage; detected automatically, override to force. |
| `type` | `video` | see above. |

!!! tip "Count the *internal* corners"
    `n_corners` counts where four squares meet, not the squares themselves. A board of 8 × 11 squares has 7 × 10 internal corners.

## Columns for `type = only_scale`

Required: `calibration_id`, `file`, `extrinsic` (a timestamp of any representative frame), and:

| column | description |
| --- | --- |
| `scale` | real-world units per pixel (e.g. cm/pixel). |

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
| `checker_size` | `12` | the real-world size of a single tag **cell** (e.g. cm). The black-border square is `cells × checker_size`, where `cells` is 8 for `tag36h11`, 7 for `tag25h9`, 6 for `tag16h5`. **Track coordinates come out in this unit.** |
| `center` | — | `"(x, y)"` pixel of the arena's origin **in the `extrinsic` frame**. Becomes the origin of the real-world coordinates. |
| `north` | — | `"(x, y)"` pixel due north of `center` in the `extrinsic` frame; rotates the coordinates so north is consistent. Requires `center`. |
| `path` | `.` | folder containing `file`, relative to the csv file. |

The tags are stationary across the whole experiment, so the reference is established once here and shared by every run — `runs.csv` therefore has no `apriltags` column (and, for an apriltag run, a run's own `start` frame is where its target search begins, not the calibration's `center`).

!!! warning "AprilTags on Apple Silicon Macs"
    `type = apriltag` calibrations currently don't run natively on Apple Silicon (M1/M2/M3/…) Macs — see [the Help page](help.md#Macs) for the workaround.

## Mixing kinds in one file

All kinds can be mixed in one file — leave a column blank on the rows where it doesn't apply:

```csv
calibration_id,type,file,extrinsic,start,stop,checker_size,n_corners,center,north,scale,apriltags,family
morning,video,calib_morning.mp4,00:00:02,00:00:05,00:00:35,4,"(7, 10)","(960, 540)","(960, 100)",,,
afternoon,,calib_afternoon.mp4,1.5,5,35,4,"(7, 10)","(955, 545)",,,,
drone,only_scale,drone_shot.mp4,0,,,,,"(2000, 1500)",,0.21,,
flight,apriltag,drone_flight.mp4,00:00:04,,,12,,"(960, 540)","(960, 100)",,4,tag36h11
```

## Next

- [Your results →](results.md)
