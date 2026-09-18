# What the `rectifications.csv` rung needs (#293)

Research for the wayfinder map #289. **Question:** what does the second rung need, the one that
enters Fromage through `rectifications.csv` and `verify`/`main`? And what does it exercise that the
builder rung (`from_checkerboard`/`from_extrinsic` called directly) does not?

Everything below was checked on `main` at `057a261` (v0.6.1), Julia 1.13.0, 32 threads, ffmpeg
from FFMPEG.jl. Code locations were confirmed with `grep_code` against the working tree. The
scripts are in [`research/csv-rung/`](research/csv-rung/), and each one runs as
`JULIA_NUM_THREADS=auto julia --project research/csv-rung/<script>.jl`. Their full output is saved
beside them (`*.out`). Every number here was printed by one of those scripts.

- `probe_sar.jl` encodes stored 1440×1080 at `sar` 4/3 and stored 1920×540 at `sar` 1/2 seven
  ways. It probes each file with all three `sar` readers Fromage has. On the lossless files it also
  checks the pixel round trip and which frame a timestamp reads.
- `csv_rung.jl` renders a 10×7-corner, 4 cm board with 4×4 supersampling and an edge-aligned
  physical squeeze, at `sar` 1, 4/3 and 1/2. Each video has six waved poses plus one flat pose, at
  1 fps, encoded `libx264 -qp 0 -pix_fmt gray`. It writes `rectifications.csv` and `runs.csv`,
  runs `verify`, then `load_rectifications` and `build_rectification`, and compares the result with
  `from_checkerboard` called directly and with analytic truth.

The sibling research note on `research/center-north-gauge` (`CENTER-NORTH-GAUGE.md`, #290) covers
what `center`/`north` do to real space. This note does not repeat it.

## Short answers

1. **Minimal csv.** One row is enough:
   `rectification_id,file,extrinsic,intrinsic_start,intrinsic_stop,temporal_step`. `type` defaults
   to `checkerboard`. `n_corners` defaults to `(7, 10)` and `checker_width` to `4.0`, and both fit
   the baseline board: the default `(7, 10)` detected a 10×7 board. `aspect`, `width`, `height` and
   `yadif` all come from the probe. **`verify` and `main` also need a `runs.csv` that uses every
   rectification id.** The internal `VerifyRectifications.load_rectifications` does not.
2. **`aspect`** is ffprobe's stream `sample_aspect_ratio`, as a `Float64`, filled in only when the
   cell is blank. `N/A`, `0:1` and malformed values become 1. A value in the csv wins.
3. **Frame addressing.** A timestamp `t` reads the **first frame whose presentation time is ≥ t**
   (`ffmpeg -ss t -i …`, input seeking). The intrinsic views are `intrinsic_start:temporal_step:intrinsic_stop`
   inclusive. The extrinsic frame is **appended to them as the last view** and fitted as well. At
   1 fps, frame *k* is `t = k`, exactly.
4. **Getting `image2real` out.** Neither `main` nor `verify` returns it. The route the test suite
   uses is internal:
   `Fromage.build_rectification(c)` for `c in Fromage.VerifyRectifications.load_rectifications(…)`.
   It is the same memoized object `main` tracks through. Measured: it is **bit-identical** to
   `from_checkerboard` called with the same keywords. Otherwise the rung can only measure through a
   track csv, which adds the tracker and #276.
5. **What the gateway adds.** Probing (width, height, `aspect`, `yadif`), the defaults (notably
   **`blur = 1.0`**, a Gaussian blur applied before every corner detection), the choice of builder
   by whether an intrinsic window is present, **integer** `center`/`north`, and a set of rejections.
   There are **no `Spaces` conversions** and **no `center`/`north` defaulting** in the gateway. Both
   happen inside the builder (`_maps` → `add_center_north`), so both rungs get them. Given the same
   keywords, the csv rung builds exactly what the builder rung builds (0.0 difference, measured). Its
   extra exposure is to *which* keywords the gateway chooses.
6. **Synthetic `sar ≠ 1` media.** They probe like bitstream-signalled anamorphic media: the gateway
   reads 4/3 and 1/2 in every encoding tried. **But the tracker reads `sar` separately (VideoIO,
   codec level), and it reads 1 when the `sar` lives only in the container** (FFV1 in mkv, or
   `-aspect` on a stream copy). See "Looks like a bug" below. `libx264 -qp 0 -pix_fmt gray` is the
   encoding on which all three readers agree **and** pixels round-trip exactly.

## 1. The minimal `rectifications.csv` and folder layout

```
data/
  board.mp4              calibration video (waved board, then the flat board)
  rectifications.csv
  runs.csv               only for verify/main; must reference every rectification_id
```

```csv
rectification_id,file,extrinsic,intrinsic_start,intrinsic_stop,temporal_step
full,board.mp4,33,0,32,1
```

For the map's 33 waved poses plus one flat pose at 1 fps: frames 0–32 are the waved board and
frame 33 is the flat one. The duration is 34 s, which satisfies `extrinsic < duration`.

The columns, and what the gateway does with each (`src/VerifyRectifications/parsers.jl:89-109`):

| column | required? | if blank |
|---|---|---|
| `rectification_id` | yes | issue |
| `file` | yes | issue; resolved as `joinpath(data_path, path, file)` then `realpath` (`src/gateway.jl:93-106`) |
| `extrinsic` | yes | issue. Seconds or `HH:MM:SS` (`src/parsing.jl:32-40`) |
| `intrinsic_start`/`intrinsic_stop` | both or neither (`parsers.jl:115-119`) | both blank → `Checkerboard{Missing}` → `from_extrinsic` |
| `path` | no | `"."` |
| `type` | no | `checkerboard` (`parsers.jl:179-180`) |
| `n_corners` | no | `(7, 10)` (`parsers.jl:18-28`) |
| `checker_width` | no | `4.0` |
| `temporal_step` | no | `2.0`. Filled in even on an extrinsic-only row, and ignored there |
| `radial_parameters` | no | `1` |
| `blur` | no | `1.0`: `gblur=sigma=1` on every frame read (`from_checkerboard.jl:16-21`) |
| `yadif` | no | probed `field_order` ∈ {tt, bb, tb, bt} |
| `aspect` | no | probed `sample_aspect_ratio` |
| `center`/`north` | no | `missing`. `NTuple{2, Int}` **only** (`types.jl:10-11`) |

`width`/`height` have no column. They always come from the probe
(`src/VerifyRectifications/verifications.jl:38-49`).

`main`'s `rectification_defaults` replaces any of the `DEFAULTS` entries globally. A cell still wins.

Runtime (`csv_rung.out`): `verify` printed, for the row with an intrinsic window at `sar` 4/3,
`aspect 1.33333, width 1440, height 1080, yadif false, blur 1.0, n_corners (7, 10),
checker_width 4.0, temporal_step 1.0, radial_parameters 1` with no issues. The extrinsic-only row
got `temporal_step 2.0`, which nothing reads.

### What `verify`/`main` reject before building (`verifications.jl:584-662`)

- `center`/`north` below 1, or beyond the **display** frame: `x > width × aspect`, `y > height`
  (`:608-617`). For stored 1920×540 at `sar` 1/2 the display width is **960**.
- `north` without `center` (`parsers.jl:121-126`, `verifications.jl:619`).
- `extrinsic ≥ duration` (`:638`), `intrinsic_start ≥ intrinsic_stop`, `intrinsic_stop > duration`
  (`:643-645`), and fewer than 3 sampled times in the window (`:648`).
- No corners at the extrinsic frame (`verify_extrinsics!`, `:429-458`). The failing frame is dumped
  under `results_dir/issues/`.
- Fewer than 3 frames with corners in the window (`_intrinsic_issue`, `:487-496`). **Frames that
  fail detection are otherwise dropped silently**, both here and in `extract_intrinsics`
  (`from_checkerboard.jl:48`, `collect(skipmissing(corners))`). Neither rung reports *which* poses
  were missed. The map treats a missed frame as a finding, so the simulation has to count
  detections itself, for example by calling `Fromage.Rectifications.get_corners(file, t, vf, w, h,
  n_corners)` per frame.
- A second checkerboard row with the same `(file, window, extrinsic, center, north)` is rejected
  as a repeat. `aspect` is **not** part of that identity (`:571-576`), so two rows that differ only
  in `aspect` cannot coexist; the later one is flagged. I read this in the code and did not run it.
  A variant grid must therefore use one file per `sar`, which it would anyway.

## 2. How `aspect` is read

`probe_video` asks ffprobe for
`stream=width,height,sample_aspect_ratio,field_order:format=duration` with `-select_streams v:0`
(`verifications.jl:281-292`, spawn in `src/probing.jl:53-64`). The `sample_aspect_ratio` string
goes through `parse_sar` → `Rational`, then `Float64` (`src/probing.jl:110-119`). It is filled in
only where the cell is blank: `g.aspect .= coalesce.(g.aspect, m.aspect)` (`verifications.jl:45`).
It then travels unchanged as `Source.aspect::Float64` (`types.jl:12`, `:72`) into the builder's
`aspect` keyword (`types.jl:109-114`, `:126-130`).

ffprobe's stream `sample_aspect_ratio` saw the `sar` in every place it can live: container only,
bitstream only, or both (§6). As I understand ffprobe, it reports `av_guess_sample_aspect_ratio`,
which prefers the container's value; I did not read ffprobe's source to confirm that. The tracker
reads only the codec's value, and that is why the two disagree on container-only files (§6).

The runs gateway probes the same file separately and keeps the exact `Rational{Int}`
(`src/VerifyRuns/verifications.jl:12-21`). There is **no csv override of `sar` on the run side**,
so a rectification row whose `aspect` cell disagrees with the probed `sar` gives the two halves of
one dataset two different `sar`s.

## 3. How `intrinsic_start`/`intrinsic_stop`/`extrinsic` address frames

Every checkerboard frame read is one ffmpeg call:
`ffmpeg -ss $t -i $file -frames:v 1 [-vf $vf] -f rawvideo -pix_fmt gray pipe:1`
(`src/Rectifications/from_checkerboard.jl:23-24`). The output is reshaped to the probed stored
`(width, height)` and transposed (`:31-34`). Intrinsic views are `start:temporal_step:stop`,
**both ends included** (`:45-49`). The extrinsic corners are `push!`ed as the last view (`:178`),
so the flat board is **also one of the calibration views**, and a flat frame inside the window is
used twice. `fit_model` takes one set of intrinsics across all views and uses the pose of the last
one (`:222-230`).

Measured at 10 fps with frame *k* ≠ frame *k′* pixel for pixel (`probe_sar.out`), identically for
every lossless encoding and both `sar`s:

| `t` | frame read |
|---|---|
| `k/10 − 1 ms` | k |
| `k/10` | k |
| `k/10 + 1 ms` | **k + 1** |
| `k/10 + 50 ms` | k + 1 |
| after the last frame's pts, but `< duration` | **no frame**: the `reshape` throws `DimensionMismatch` |

So `t` selects the first frame with pts ≥ `t`. **Address frame *k* as exactly `k / fps`**, with
`fps` chosen so that `k / fps` is exact or rounds down. `fps = 1` makes every timestamp an integer.
A timestamp just past a frame's pts reads the *next* frame, silently. The last row matters to
verification: `extrinsic < duration` (`verifications.jl:638`) accepts a `t` between the last frame
and the container's end, and that `t` reads nothing. That case is reported as a corner-detection
issue, not a time-stamp one.

## 4. Getting `image2real` back out

- `main` returns `nothing` (`src/main.jl:329`; DECISIONS, "Two entry points, and `main` returns
  nothing (#256)"). A builder writes nothing (#209). `verify` returns only the annotated DataFrames
  (`main.jl:354-365`).
- **The supported-in-practice route is internal, and it is the one the suite uses**
  (`test/fromage.jl:38-43`, `:85-90`):

  ```julia
  cs = Fromage.VerifyRectifications.load_rectifications(data_path, joinpath(data_path, "rectifications.csv");
                                                        defaults = (;), results_dir = mktempdir(), progress = false)
  rect = Fromage.build_rectification(only(filter(c -> c.rectification_id == "full", cs)))   # main.jl:118
  rect.image2real, rect.real2image, rect.ratio, rect.width, rect.height
  ```

  `load_rectifications` runs the same parse, probe, verification and `build_methods` as `main`,
  but on one file, without `runs.csv` and without the cross-file check. `build_rectification` is
  memoized on the `RectificationMethod`, so after `main` in the same session it returns `main`'s
  own object. `test/fromage.jl:90` asserts that with the memo's hit counter.
  `VerifyRectifications.load_rectifications` is exported from its submodule. `build_rectification`
  and `Rectification` are not exported from `Fromage`. Both are internal names, and a refactor may
  move them.
- **Measured:** `max |gateway − builder rung|` over the 70 extrinsic corners was **0.0 cm** at
  `sar` 1, 4/3 and 1/2. The builder rung here was `from_checkerboard` with `aspect = sar`,
  `blur = 1.0`, `yadif = false`, `n_corners = (7, 10)`, `checker_width = 4.0`,
  `radial_parameters = 1`. The csv rung adds **no transformation of its own** to the map. It only
  chooses the keywords.
- **Measuring only through a track** (`<run_id>.csv` from `main`) adds the tracker: the 1-based vs
  0-based offset (#276), the tracker's own `sar` source (§6), and detection noise. It is a third
  rung, not a substitute for the second.
- The `rectification_diagnostics` jpeg (`results_dir/rectifications/<id>.jpg`) is a warped image,
  not a quantitative output.

## 5. Every transformation between the csv and the builder keywords

In pipeline order. **Bold** marks where the csv rung differs from calling the builder by hand.

1. `read_rows` (`gateway.jl:43-53`): an unknown column or a renamed column is a file-level error.
2. `parse_row` (`parsers.jl:176-204`): cells are trimmed and blank means absent. **`type` defaults
   to checkerboard.** Temporal cells take seconds or `HH:MM:SS`. **`n_corners`, `checker_width`,
   `temporal_step`, `blur`, `radial_parameters` take `DEFAULTS` or `rectification_defaults`.**
   **`center`/`north` parse as `NTuple{2, Int}`, so sub-pixel values are a "wrong format" issue.**
   Only one intrinsic bound filled nulls both, with an issue. `north` without `center` is dropped,
   with an issue.
3. `verify_ids!`: unique, file-name-safe ids.
4. (`verify`/`main` only) `verify_cross_references!` against `runs.csv` (`gateway.jl:211-231`,
   `main.jl:195`).
5. `resolve_paths!`: **`file` becomes a canonical absolute path.** That path is the key for every
   memo (§7).
6. `read_video_metadata!`: **`width`/`height` from the probe; `aspect` from the probe if blank;
   `yadif` from `field_order` if blank** (`verifications.jl:24-49`).
7. The value and range checks and the two detection passes (§1).
8. `build_methods` → `RectificationMethod(row)` (`types.jl:72-85`): **an intrinsic window selects
   `Checkerboard{Float64}` → `from_checkerboard`; none selects `Checkerboard{Missing}` →
   `from_extrinsic`**, which drops `temporal_step`/`radial_parameters` and fits with
   `radial_parameters = 0` and a fixed principal point (`from_checkerboard.jl:198-209`,
   `detect_fit.jl:42`).
9. `Rectification(c)` passes the fields by keyword (`types.jl:109-130`). No arithmetic.

Inside the builder, and therefore on **both** rungs:

- `_vf(yadif, blur)` → `yadif=1` and/or `gblur=sigma=$blur` on every frame read
  (`from_checkerboard.jl:16-21`).
- `fit_model(sz = (height, width), …, aspect)` seeds `cammat[2, 2] = aspect` under
  `CALIB_FIX_ASPECT_RATIO` (`detect_fit.jl:28-42`). This is the wrong direction for `sar ≠ 1`
  (#275).
- `_maps` (`from_checkerboard.jl:241-249`): `default_center` (`center_north.jl:37`) fills a missing
  `center` with the display frame centre `(width·aspect/2, height/2)`. `add_center_north`
  (`center_north.jl:40-45`) converts `center`/`north` with `Spaces.to_stored`:
  `(x, y) → (y, x/aspect)` (`src/spaces.jl:58`, `:75-78`). **This is the only `Spaces` conversion
  on the path, and it is in the builder, not the gateway.**

Measured consequences (`csv_rung.out`, Procrustes RMS residual of the extrinsic corners mapped by
`image2real` against true board coordinates; reflection allowed because real space is `(y, x)`;
det = −1 throughout):

| row | sar 1 | sar 4/3 | sar 1/2 |
|---|---|---|---|
| `full` (csv, `from_checkerboard`) | 0.0189 mm | 8.97 mm | 6.05 mm |
| `extr` (csv, `from_extrinsic`) | 0.262 mm | 9.69 mm | 1.24 mm |
| `gauged` (csv, integer `center`/`north`) | 0.0189 mm | 8.97 mm | 6.05 mm |
| builder, `aspect = 1/sar` (#275's control) | 0.0189 mm | **0.0126 mm** | **0.0176 mm** |

- The whole `sar ≠ 1` shape error is #275. With the seed inverted it falls back to the `sar = 1`
  level, so on these media the csv layers add no `sar`-dependent shape error of their own.
- `from_extrinsic` is 0.26 mm off even at `sar = 1`, because it pins the principal point at the
  frame centre and the rig's principal point is offset by (13, −7) px. The map should expect this
  from any row without an intrinsic window.
- `CALIB_CB_FAST_CHECK` did **not** reject these anamorphic boards. Every frame was detected at
  4/3 and 1/2. The board here spans about 780 display px, much larger than in #290's
  `ordering.jl`, where detection failed (#288). Board size in frame is a plausible cause. I did not
  isolate it.
- **The integer gauge.** With `center`/`north` rounded to display integers (the csv can hold
  nothing else), the true centre landed at `(0.047, −0.035)` cm at `sar` 1 and north was rotated
  by 0.18°. Passing the exact floats to the builder gave `(0.0, 0.0)` and 180.000°. The residual is
  unchanged because Procrustes absorbs the gauge. **Point-by-point comparison on the csv rung must
  either use the Procrustes residual, or compute its truth from the integer pixels actually
  written**: back-project the rounded `center`/`north` through the true camera and use those as
  `C` and `N` in #290's formula.
- **Supply `center`/`north` as `(col·sar, row)` of the analytic *stored* projection**, as #290
  says, not as a coordinate in the physical display. With an edge-aligned physical squeeze, stored
  column *c* sits at physical display `sar·(c + ½) − ½`, while Fromage's display is `sar·c`. The
  two differ by `½(sar − 1)` display px: +⅙ at 4/3 and −¼ at 1/2. `csv_rung.jl`'s "direct(exact)"
  used the physical display and shows a residual centre offset at `sar ≠ 1`, mixed with #275's
  error. This is a convention for the simulation to match, not a Fromage defect. Fromage defines no
  pixel origin (#276).

## 6. Do synthetic `sar ≠ 1` media probe like real anamorphic media?

`probe_sar.out`. For stored 1440×1080 at 4/3 and stored 1920×540 at 1/2:

| encoding | ffprobe `sar` | `VerifyRectifications.probe_video` | `VerifyRuns.probe_video` | `VideoIO.aspect_ratio` (tracker) | pixels round-trip |
|---|---|---|---|---|---|
| x264 `-qp 0`, yuv420p, `setsar` (the Fixtures route) | 4:3 / 1:2 | 1.333 / 0.5 | 4//3 / 1//2 | 4//3 / 1//2 | **off by 1** |
| x264 `-qp 0`, **gray** (muxed yuvj420p), `setsar` | 4:3 / 1:2 | ✓ | ✓ | ✓ | **exact** |
| FFV1 gray in mkv, `setsar` | 4:3 / 1:2 | ✓ | ✓ | **1//1** | exact |
| x264, `sar` only in the H.264 VUI (`h264_metadata` bsf) | 4:3 / 1:2 | ✓ | ✓ | ✓ | — |
| x264 square VUI, `sar` only in the mp4 `pasp` (`-aspect`, stream copy) | 4:3 / 1:2 | ✓ | ✓ | **1//1** | — |
| same, in mkv | 4:3 / 1:2 | ✓ | ✓ | **1//1** | — |
| MPEG-2 in MPEG-TS, HDV-style (lossy) | 4:3 / 1:2 | ✓ | ✓ | ✓ | — |

- Every file reports display aspect 16:9 and `field_order=progressive`, so `yadif = false`.
- **Real anamorphic formats** (HDV MPEG-2, AVCHD/H.264 at 1440×1080) signal `sar` in the
  bitstream: the MPEG-2 sequence header or the H.264 VUI. The two rows that reproduce that
  (VUI-only, and MPEG-2 in TS) agree across all three readers. So does the plain `setsar` x264
  file, which carries `sar` in both places. **I had no real anamorphic file to compare against.**
  Every lab file I found (`.MTS`, `.MP4`, `.mov`, all 1920×1080) probes `1:1`. The claim that real
  media probe this way rests on how those formats are specified, not on a measurement.
- The **"off by 1"** row is gray raw input encoded as yuv420p: a full-range → limited-range
  conversion, and back on read. It is not lossless in the pixel values. `-pix_fmt gray` with
  libx264 keeps full range (yuvj420p) and was exact. **Recommended encoding for the simulation:
  `-f rawvideo -pix_fmt gray … -vf setsar=N/D -c:v libx264 -qp 0 -pix_fmt gray`.** Use FFV1/mkv
  only if the tracker is never involved.
- The mkv container-only row reported **25 fps** in `VerifyRuns`. That is an artefact of my
  construction (a raw `.h264` intermediate carries no timing), not a finding.
- MPEG-TS files print every stream field twice from ffprobe (once per program). `_probe_fields`
  collects them into a `Dict`, so the duplicates are harmless.
- **For `sar < 1`, Fromage's display space is the physical display scaled by `sar`.** Stored
  1920×540 at `sar` 1/2 is 960×540 display px. If the rig's display stays 1920×1080 with f ≈ 900,
  then in Fromage's display units f is 450, the frame centre is `(480, 270)`, and `center`/`north`
  are bounded by 960×540. `csv_rung.jl` builds its `sar = 1/2` rig this way.

### Looks like a bug: the tracker reads `sar` from a different place than both gateways

`PawsomeTracker.Video` takes `sar = aspect_ratio(vid)` (`src/PawsomeTracker/PawsomeTracker.jl:257`).
That is VideoIO's **codec-context** `sample_aspect_ratio` (VideoIO 1.9.0, `src/avio.jl:740-749`).
Both gateways read ffprobe's **stream** value, which prefers the container. When `sar` is only in
the container, they disagree. Reproduction:

```sh
ffmpeg -f lavfi -i testsrc=size=1440x1080:rate=10:duration=1 -vf setsar=4/3 -c:v ffv1 -pix_fmt gray a.mkv
ffmpeg -f lavfi -i testsrc=size=1440x1080:rate=10:duration=1 -c:v libx264 -qp 0 -pix_fmt gray sq.mp4
ffmpeg -i sq.mp4 -c copy -aspect 16:9 b.mp4
julia --project -e 'using Fromage, VideoIO; for f in ("a.mkv", "b.mp4")
    println(f, ": VerifyRuns sar = ", Fromage.VerifyRuns.probe_video(f).sar,
            ", VerifyRectifications aspect = ", Fromage.VerifyRectifications.probe_video(f).aspect,
            ", VideoIO.aspect_ratio = ", VideoIO.openvideo(VideoIO.aspect_ratio, f)); end'
```

Printed:

```
a.mkv: VerifyRuns sar = 4//3, VerifyRectifications aspect = 1.3333333333333333, VideoIO.aspect_ratio = 1//1
b.mp4: VerifyRuns sar = 4//3, VerifyRectifications aspect = 1.3333333333333333, VideoIO.aspect_ratio = 1//1
```

On such a file the run gateway bounds-checks `start_location` against `width × 4/3`, and the
rectification is built with `aspect = 4/3`. The tracker, however, converts `start_location` to
stored (`get_guess`, `PawsomeTracker.jl:188`) and the window's column extent (`Tracker`, `:307`)
with `sar = 1`. This is the second-definition-site shape that the comment beside `Video`
(`:222-226`) argues against for `native_fps`. **Not verified:** that a track actually goes wrong
on such a file. I read the consequence from the code and did not run it. Nor did I check how
common container-only `sar` is in lab footage. Every lab file I found is square.

## 7. Practical hazards for the simulation driving the csv rung

- **The memos are keyed on the file path and never revalidated** (DECISIONS, "The memo is keyed
  on the path, and never revalidated"). A variant rendered to a path that an earlier variant used
  in the same Julia session is served the earlier probe, detections and build. Give each variant
  its own path, or call `Fromage.empty_caches!()` (`main.jl:387`) between variants.
- `verify`/`main` need `runs.csv`, and every rectification id must be used by a run
  (`gateway.jl:211-231`). `main` then **tracks** those runs. For the csv rung, `verify` plus
  `load_rectifications` plus `build_rectification` measures the rectification without tracking.
  `main` is only needed if the rung is meant to include the tracker.
- The default `blur = 1.0` is part of what the csv rung measures. The builder rung should pass
  `blur = 1.0` explicitly to stay comparable, or both should set it deliberately.

## Not verified

- **Real anamorphic media.** There was none on this machine. All seven encodings are synthetic,
  and the "probes like real" claim rests on how HDV and AVCHD signal `sar` in the bitstream.
- **`main` end to end** on these media, meaning build and then track. Only `verify`,
  `load_rectifications` and `build_rectification` were run. Nothing was tracked.
- **That the tracker's `sar = 1` on container-only files damages a track.** This comes from
  reading the code (§6).
- **The duplicate-row rule for rows that differ only in `aspect`** (§1). I read it in the code and
  did not run it.
- **An `aspect` cell overriding the probe.** I read it at `verifications.jl:45` and did not run it.
- **Interlaced, field-separated sources.** Every file here is progressive. I did not test what a
  real `sar = 1/2` field-separated source reports for `field_order`, and so whether `yadif` would
  be imputed `true` for it.
- **Frame addressing** was measured at 10 fps on files with no B-frame reordering issues visible.
  Encodings with an edit list or a non-zero start pts were not tried.
- **Why `CALIB_CB_FAST_CHECK` accepted these boards** when #290's smaller boards were rejected (§5).
  I did not isolate board size as the cause.
- The residuals come from one set of seven poses, one run per `sar`, with no replicates.
