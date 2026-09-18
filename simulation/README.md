# CalibrationRigSimulation

A physical simulation of the arena and camera, used as ground truth for Fromage's checkerboard
rectification: a fully specified **baseline rig** whose every projection is known analytically,
checked stage by stage against Fromage, and **variants** of it that show where Fromage's model of
the system departs from the physics. The spec is the wayfinder map
[#289](https://github.com/yakir12/Fromage.jl/issues/289), broken into build issues in
[#297](https://github.com/yakir12/Fromage.jl/issues/297).

It is a research instrument: it reports discrepancies and gates nothing. It runs no CI and cuts no
release (`DECISIONS.md`, "The simulation runs no CI and cuts no release").

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
  poses (23 waved at the frozen angles, four corner poses, the flat board). A pose's analytic corner
  projections are `project.(Ref(cam), inner_corners(board))`.
- `src/dots.jl` — the simulation's own dot detector, `detect_dots`: a sub-pixel centroid whose
  background is the arena, never estimated from the whole frame (#283). Its truth is `area_centroid`,
  the centroid of the dot's projected area, 0.04 px from the projection of its centre (#292).
