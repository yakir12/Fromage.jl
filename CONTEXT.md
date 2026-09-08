# Context

What the words mean.

Fromage turns lab video into real-world tracks. This file is the domain model: the entities, what
they are called, and the rules that decide a name. It describes the package **as it is**, not how it
got here — for why an alternative was rejected, see `DECISIONS.md`; for how to work in the repo, see
`CLAUDE.md`.

Read this before naming anything.

---

## The two files a user writes

Everything starts with one folder holding videos and two csv files.

| file | one row per | describes |
|---|---|---|
| `rectifications.csv` | rectification | how pixels in one camera view become real-world coordinates |
| `runs.csv` | run *video* | an experimental run to track, and how to track it |

They are joined on `rectification_id`, which is a column of both.

---

## Run

**One repeat of an experiment.** One trial, one animal crossing the arena once. Experiments answer
scientific questions through repetition, and each repeat is a run.

A run is an **event in the world, not a file**. Fromage meets it twice: as the `runs.csv` rows
describing it, and as the **track** it yields.

- A run may be recorded across several video files. Each piece is a **segment**. They are one run
  because they share a `run_id`.
- A run therefore has **one timeline, one set of run-level parameters, and one track file** —
  however many videos it spans.

"Run" never means an execution of Fromage (that is a **session**) and never means the track.

### Segment

One piece of a run: a video file and the window of it to track. "Segment" names a *division of the
run*, whether you look at it as the input video portion or the track portion it yields.

### Track

What a run yields: timestamps paired with the target's position, in real-world coordinates. Written
to `results_dir/<run_id>.csv`, and returned by `main` in a column called `track`.

### Session

**One execution of Fromage.** Named because the issues folder is per execution — each session gets
its own time-stamped folder, and nothing is ever deleted from it.

### Target

The thing being tracked. Usually an animal; the tracker only cares that it is a blob of known
approximate width that differs in brightness from its background.

### Arena

The physical surface the target moves on. Real-world coordinates are coordinates on the arena floor.

---

## Rectification and calibration

These are **not** synonyms, and the boundary is decided by machine-vision usage rather than by who
is reading:

- **Calibration** — estimating a camera model: intrinsics (focal length, principal point,
  distortion) and/or extrinsics (pose). The output is a camera model.
- **Rectification** — warping an image to remove perspective (here: to a top-down metric view of
  the arena floor), and by extension the transform that performs it.

**Fromage's product is a rectification.** Only two of its four methods involve a camera calibration
at all, which is why the file is `rectifications.csv` and not `calibs.csv`.

| `type` | what it does | camera calibration? |
|---|---|---|
| `checkerboard` | fits a lens model from a waved board, then anchors it on a flat board | **yes** — the only place `OpenCV.calibrateCamera` is called |
| `matlab` | reads a camera model from a MATLAB Camera Calibrator `.mat` | **imported** |
| `apriltag` | fits a homography from coplanar tags, and registers every frame to a shared space | no |
| `uniform` | a declared pixel width; a uniform scaling and nothing else | no camera model at all |

Camera-calibration vocabulary is correct **only where a method genuinely performs or imports one** —
the intrinsic window (`intrinsic_start`/`intrinsic_stop`), `checker_width`, `n_corners`,
`radial_parameters`, and everything MATLAB. It is never the name of the concept, the file, or the id.

### The one deliberate generalisation

**`extrinsic`** is a column of all four types. It is literally the pose-anchoring frame for
`checkerboard` and `matlab`; for the other two it means "the frame this rectification is anchored
to". One generalisation beats a third vocabulary word.

---

## The three stages, on both sides

Both halves of the pipeline have the same shape, and each stage has its own name:

| stage | rectification side | run side |
|---|---|---|
| **declaration** — what the user wrote | a `rectifications.csv` row | the `runs.csv` rows sharing a `run_id` |
| **verified** — parsed, checked, probe-filled | `RectificationMethod` (`Checkerboard`, `Apriltag`, `MATLAB`, `Uniform`) | `Run` |
| **the product** | `StaticRectification` / `ApriltagRectification` | the track |

One asymmetry worth knowing: on the run side every field is concrete by the time a `Run` exists. On
the rectification side it is not — some absences are load-bearing. A `Checkerboard` with **no
intrinsic window** (both bounds blank) selects a different builder: the extrinsics-only fit. Absence
is a choice there, not a gap.

### Gateway

The csv → verified-value pipeline: read, parse, check, impute, report. There is one per file
(`VerifyRectifications`, `VerifyRuns`) sharing its plumbing but not its rules. Internal jargon —
users never see the word.

---

## Frame and space

Machine vision overloads "frame": a *video frame* is an image, a *frame of reference* is a
coordinate system. Fromage is a video pipeline, so:

> **Bare "frame" means an image. Every coordinate system is a "space".**

Every other sense takes a qualifier — the model is `DataFrame`, a third meaning that confuses nobody
because it is always compounded, never bare.

### The coordinate spaces

| space | what it is | axis order |
|---|---|---|
| **stored** | pixels as encoded in the file; what ffprobe reports | `(row, col)` for a point, `(col, row)` for an extent |
| **display** | stored corrected by `sar` — what an image viewer shows | **`(x, y)`** |
| **scaled** | after `downscale`; what the tracker's buffers cover | `(row, col)` |
| **canvas** | a fixed-size render target (the diagnostic square, the AprilTag viewport) | `(row, col)` |
| **reference** | the AprilTag shared space every run frame registers into | **`(x, y)`** |
| **metric** | AprilTag ground units from the tag fit, before the centre/north gauge | **`(x, y)`** |
| **real** | the output: metric after the gauge, or `image2real` for the fixed maps | `(y, x)` |

`display` → `stored` is `sar` **and a swap** — `(x, y) → (y, x / sar)`, which is `fix_coordinate`.
`scaled` is `downscale`. `metric` → `real` is `XY_SWAP` composed with centering and northing.

**Three of the seven use `(x, y)`, and `stored` uses both orders.** Everything a user writes —
`center`, `north`, `start_location`, `window_size` — is **display `(x, y)`**, because that is what an
image viewer reports. Most things internal are `(row, col)`, but the AprilTag geometry is not: tag
corners, `ReferenceSpace.corners` and everything `apply_h` touches are `(x, y) = (col, row)`, which
is why `img_to_ground` exists to bridge the two. The registered *buffer* is still an array, so
indexing it is `(row, col)` like any other — `reference` names the coordinate convention, not the
storage.

Nothing in the type system catches a transposition. `start_location`, `center` and `north` are
`NTuple{2, Int}`; `window_size` is `Union{Int, NTuple{2, Int}}` and is usually the bare `Int`; the
internal `RowCol` is an `SVector{2, Float32}` whose name is a claim, not an invariant (the AprilTag
path stores metric `(x, y)` in one). That is why `Segment`'s constructor *asserts* its type rather
than converting, and why `XY_SWAP` is a named constant rather than an inline reversal. It is also
why `stored` carries both orders undetected: `:dimension` is ffprobe's `(width, height)`, while
`from_checkerboard`'s `sz` is `(height, width)` for the same frame.

**"Canvas" is overloaded in the source.** The table's sense is the render target. `PawsomeTracker`
also calls the tracker's working buffer a canvas (`Tracker`'s `sz`, `canvas2raw`, `build_stack`),
and that one is `scaled` — or, in AprilTag mode, the scaled `reference` viewport. Same axis order,
different space.

### "Metric" is not a claim about SI

A *metric* reconstruction is one where true distances are recoverable, as opposed to projective or
affine. The unit is whatever the user measured in — `checker_width`, `tag_cell_width` or
`pixel_width` sets it, and the track comes out in that unit. Nothing in the package should assert
centimetres.

### "Real" has a second, unrelated sense

*Real-world coordinates* is the output space. But *"the real frame size"* and *"reads real frames"*
mean **actual**, as opposed to declared or synthetic. Only the first is a space.

---

## Tracking parameters

A *tracking parameter* is a value `runs.csv` supplies to `track`. They divide by **scope** — whether
a value belongs to the whole run or varies between its segments — and that division is what
separates the two types carrying them:

- `Segment` holds what varies within a run — `file`, `start`, `stop`, `start_location`.
- `Tuning` holds what one run shares. The name is narrower than the contents: three of its eight
  fields are observations rather than choices — `native_fps` (the rate the video runs at),
  `darker_target` (a property of the footage) and `target_width` (a measurement of the animal).
  Membership is not "knobs": it is *run-level, and an argument of `track`*.

`verify_run_consistency!` is that scope rule enforced — segments of one run must agree on every
run-level column.

Run-level alone does not make a tracking parameter. `frame_format` (the frame's stored `width` and
`height`, and its `sar`) is run-level and is checked for agreement, but it sits beside `Tuning` on
`Run` rather than on it: the gateway consumes it, to place a start location, and `track` never
receives it.

A *rectification parameter* is the same idea one gateway over: a value `rectifications.csv`
supplies to a rectification builder.

---

## One definition site

Every tracking and rectification parameter is defined in exactly one place, and this is enforced by
`test/quality.jl`:

- every `Tuning` and `Segment` field is a `runs.csv` column
- every rectification builder keyword is a `rectifications.csv` column
- `track` takes **no** keyword arguments

The gateways impute; `track` and the builders do not. Every value arrives concrete, decided in
exactly one place upstream — a csv cell, a `defaults` entry, or the gateway's probe of the video.

This is why a csv rename must travel into the code, and why it cannot be half-applied.
