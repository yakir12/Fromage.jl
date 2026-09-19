# CalibrationRigSimulation

A physical simulation of the arena and camera, used as ground truth for Fromage's checkerboard
rectification: a fully specified **baseline rig** whose every projection is known analytically,
checked stage by stage against Fromage, and **variants** of it that show where Fromage's model of
the system departs from the physics. The spec is the wayfinder map
[#289](https://github.com/yakir12/Fromage.jl/issues/289), broken into build issues in
[#297](https://github.com/yakir12/Fromage.jl/issues/297).

It is a research instrument: it reports discrepancies and gates nothing. It runs no CI and cuts no
release (`DECISIONS.md`, "The simulation runs no CI and cuts no release").

## Running it

```julia
using CalibrationRigSimulation
simulate(; results_dir = "/somewhere/results", cache_dir = "/somewhere/cache")
```

Neither folder has a default, and both belong outside the repository. `variants` picks rigs by name
(`variants = ["baseline"]`) or takes `Rig`s. Each run writes `report.csv` into its own folder of
`results_dir`, named for the date, Fromage's version and commit, the simulation's version and
Julia's; it prints a table of the primary quantities and returns the report as a `DataFrame`.
It first measures ten seeded replicates of the baseline, each board shifted in its own plane by up
to half a stored pixel at its depth. Their rows are saved alongside the report in `replicates.csv`.
The first run renders eleven videos (the ten replicates and the baseline), about a minute each on
32 threads; later runs read them from `cache_dir` and repeat the measurements against Fromage.

Every rig is judged against the **baseline's floor**, even when `variants` leaves out the baseline:
the largest error magnitude across its ten replicates for the `total` family, and the baseline's
analytic-corner controls for the `model` family (the largest across the ten seeds for
`from_extrinsic`). A variant with a higher noise floor is therefore judged against a floor too low.
The csv adds `floor`, `ratio`, `tolerance`, `family` and `verdict`:

- Missed frames are `serious`; absent map values are `n/a`.
- Total map errors are `serious` above both 3× the floor and 1 mm RMS / 3 mm max; dot separation
  uses 3× and 1 mm. Corners and intrinsic errors are only `diagnostic`, above 3×.
- Model map errors are `serious` above both 10× the control floor and 0.1 mm.
- RMS and max are judged; p95 and the other unjudged rows are `n/a`. Ratios use magnitudes;
  zero over zero is 0, and a nonzero error over a zero floor has an infinite ratio.

The printed table marks serious values `!!` and diagnostic values `!`, states whose floor is used,
and ends with the serious rows. These are aids for exploring, not pass/fail gates
([#296](https://github.com/yakir12/Fromage.jl/issues/296)).

## Running the tests

From the repository root:

```sh
JULIA_NUM_THREADS=auto julia --project=simulation -e 'using Pkg; Pkg.test()'
```

Fromage comes from the parent folder (`[sources]` in `Project.toml`); the `Manifest.toml` is not
tracked. OpenCV is a test-only dependency: an oracle for the camera model, never used by it.

## Vocabulary

The simulation's own words, kept here rather than in the root `CONTEXT.md`, which describes Fromage.

- **rig** — the complete simulated physical setup: its objects, the camera, the board poses. Not
  "scene" (the diagnostic writer's word), not "system", not "draw".
- **baseline rig** — the fully specified rig of #289.
- **setting** — one adjustable property of a rig (`sar`, `k1`, …).
- **variant** — a rig that differs from the baseline in one or more settings.

## What is here

- `src/camera.jl` — the camera model: pinhole + radial (`k1`, `k2`, `k3`), world → stored pixel
  (`project`) and back (`ray`), with a bracketed inverse and an explicit fold guard. Pixels are
  0-based with centres on integers; the optics are specified in display px of the 1920×1080 frame,
  and a stored column is display x / `sar`. At `sar < 1` the field of view stays fixed: Fromage
  displays that frame smaller, and the focal length and principal point scale with it.
- `src/objects.jl` — the rig's objects as geometry plus reflectance, never images: the arena, the
  two dots, the floor and the `Board`. `trace` casts one ray into them, with the precedence stated
  once: board over dot over arena over floor.
- `src/render.jl` — the ideal sensor: `render` makes each stored pixel the mean reflectance over
  16×16 rays cast backwards through the camera model (#292), 8 bit, threaded over rows. It returns a
  column-major matrix; raw video is row-major.
- `src/poses.jl` — the baseline rig as data: `BASELINE_CAMERA`, and `board_poses`, its 28 board
  poses (23 waved at the frozen angles, four corner poses, the flat board), and `corner_projections`,
  the analytic projections of a pose's inner corners.
- `src/dots.jl` — the simulation's own dot detector, `detect_dots`: a sub-pixel centroid whose
  background is the arena, never estimated from the whole frame (#283). Its truth is `area_centroid`,
  the centroid of the dot's projected area, 0.04 px from the projection of its centre (#292).
- `src/encode.jl` — `encode`: frames to a lossless video, gray x264 at `-qp 0` with the `sar` set by
  `setsar`, one frame per second so frame `k` is at `t = k` s. On it Fromage's frame reader returns
  the rendered pixels exactly, and both gateways' ffprobe and the tracker's VideoIO read the `sar`
  (#293).
- `src/cache.jl` — `cached_video`: a rig's video, rendered once into a `cache_dir` (no default: keep
  it outside the repository) under a hash of the camera, the boards, the sampling and
  `RENDERER_VERSION`. **Bump `RENDERER_VERSION` by hand whenever rendering changes**, or the cache
  keeps serving the old videos.
- `src/truth.jl` — what Fromage's map is checked against: the `Gauge` (`center` and `north` snapped
  to whole display pixels and back-projected onto the ground, #294), the 5 cm grid over the arena,
  `map_errors` in its four splits (whole arena, on the flat board's footprint, off it, after
  Procrustes), and RMS / p95 / max.
- `src/builder_rung.jl` — the builder rung: detection of the 28 frames counted with Fromage's own
  detector, corners against their analytic projections, `from_checkerboard` and `from_extrinsic`
  called as the csv calls them (`blur = 1.0`), each intrinsic term, the map, and the dot separation;
  the analytic-corner controls; and the run-time self-checks (the round trip, the dot detector, the
  analytic control).
- `src/csv_rung.jl` — the CSV rung: the same snapped gauge and simulated video entering through
  `rectifications.csv` and `runs.csv`, verified and read back through the rectification gateway.
- `src/report.jl` — the long-format report, one row per rig × rung × builder × section × quantity ×
  split × statistic, each with a `status` (`ok`, `not detected`, `threw: <message>`), and the
  printed table.
- `src/floor.jl` — seeded board jitter and the baseline's replicate and control floors.
- `src/verdicts.jl` — the two verdict families, thresholds and the columns they add to each row.
- `src/simulate.jl` — `simulate`, `Rig` and `VARIANTS`, the rigs a run can measure (the baseline
  only, for now).
