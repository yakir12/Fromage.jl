# How `center` and `north` place world coordinates in real space (#290)

Research for the wayfinder map #289. **Question:** for a `checkerboard` rectification, when
`center`/`north` are the exact projections of two known world points on the arena, what real
coordinates does Fromage's `image2real` return for a world point `(X, Y)`?

Everything below was checked on `main` at `057a261` (v0.6.1), Julia 1.13.0, 32 threads. The scripts
are in [`research/center-north-gauge/`](research/center-north-gauge/), and each one is run as
`JULIA_NUM_THREADS=auto julia --project research/center-north-gauge/<script>.jl`. Code locations were
confirmed with `grep_code` against the working tree. Every number here was printed by one of those
scripts.

## The answer

Suppose `center` is the projection of world point `C` and `north` the projection of world point
`N`, both on the arena plane `Z = 0`. Define

```
u  = (N − C) / |N − C|         unit vector from centre to north, in world (X, Y)
u⊥ = (−u_Y, u_X)               u rotated +90° (counter-clockwise, seen from +Z)
```

Then for any world point `P = (X, Y)` on the arena plane:

```
image2real(stored(P)) = (y, x) = ( −(P − C)·u ,  −s · (P − C)·u⊥ )
```

Here `s = +1` for every board the probe rendered (see *Handedness*). Lengths come out in the unit of
`checker_width`.

**The map's choice**, with `C` = the origin and `N = (0, Y₀)` for some `Y₀ > 0` (for example the
dot at `(0, +0.5 m)`), reduces to

```
(y, x) = (−Y, X)
```

With `N` on the `+X` axis instead, it is `(y, x) = (−X, −Y)`.

Read as a `(row, col)` layout, real space is the arena seen from above (Z up) with north at the
top. `y` grows **away** from north. `x` grows toward "east", north turned clockwise as on a map. The
map from world `(X, Y)` to `(y, x)` is a proper rotation (determinant +1) plus a translation. The
gauge introduces no mirror.

Runtime check, `gauge.jl`: `_maps` was fed the **true** camera model, and the formula was compared
at 87 arena points out to 1 m radius, the two dots and the origin included. The worst case over
all 8 possible board orderings and every `sar` in {1, 0.5, 10/11, 16/15, 64/45, 2} was
**2.1e-14 m**. The same bound held for a general pair `C = (0.13, −0.21)`,
`N = (−0.4, 0.37)`: **2.5e-14 m**. Example output (`sar = 1`, `s = +1`):

```
world (X,Y)=(+0.00,+0.50) -> real (y,x)=(-0.500000,+0.000000)
world (X,Y)=(+0.30,+0.00) -> real (y,x)=(+0.000000,+0.300000)
world (X,Y)=(+0.00,-0.50) -> real (y,x)=(+0.500000,-0.000000)
world (X,Y)=(+0.20,+0.10) -> real (y,x)=(-0.100000,+0.200000)
```

## How it is built

### The composition

`_maps` builds the board-frame map and hands it to the gauge
(`src/Rectifications/from_checkerboard.jl:245`, `:248`):

```
image2real = ∘(pop, inv_scale, inv_extrinsic, inv_perspective_map, inv_distort, inv_intrinsic)
```

`add_center_north` then prepends the gauge (`src/Rectifications/center_north.jl:40-45`):

```
image2real = northing ∘ centering ∘ image2real          # :43
real2image = real2image ∘ inv(centering) ∘ inv(northing) # :42
```

- **`i2r_centering`** (`center_north.jl:1-4`) is `Translation(−image2real(c))`. It uses the
  *ungauged* real coordinate of the `center` pixel, so `center` lands on `(0, 0)`.
- **`i2r_northing`** (`center_north.jl:7-11`) takes `p` = the centred real coordinate of `north`
  and returns `LinearMap(Angle2d(π − atan(p[2], p[1])))` (`:10`). That rotation takes the angle
  `φ = atan(p₂, p₁)` to `π`, so `north` lands on `(−|p|, 0)`. In real's `(y, x)` order (see
  `CONTEXT.md`) that is the **negative y axis**, up the canvas, which is what the comment at
  `src/PawsomeTracker/apriltag.jl:552` says. With `north` missing the rotation is the identity
  (`center_north.jl:6`); I did not run that case.
- `center` and `north` both go through `to_stored(·, aspect)` first (`center_north.jl:41`).

A small naming drift, not a behaviour bug: `DECISIONS.md:1700` and the comments in
`test/Rectifications/test_geometry.jl:24,50` say north lands on the "−x axis". They mean component 1
in the maths `(x, y)` sense. In `CONTEXT.md`'s `(y, x)` naming for real space, component 1 is `y`.

### Real space before the gauge: the board's own frame

- `objpoints` are `XYZ.(Tuple.(CartesianIndices((0:n₁−1, 0:n₂−1, 0:0))))`
  (`from_checkerboard.jl:217`). Object point `(i, j, 0)` is paired with element `[i+1, j+1]` of the
  `Matrix{RowCol}(undef, n_corners)` that `findChessboardCorners` fills (`detect_fit.jl:7-13`), in
  OpenCV's order. Axis `i` runs along `n_corners[1]`.
- `obj2img`'s scale is `LinearMap(SDiagonal{3}(I / checker_width))` (`from_checkerboard.jl:54`), and
  `image2real` applies its inverse. The ungauged real coordinate of grid corner `(i, j)` is therefore
  **`(i·checker_width, j·checker_width)`**, with the origin at the corner OpenCV returned first.
- **Units.** `gauge.jl` maps corner `(2, 3)` to `(2·cw, 3·cw)` with an error of at most 3.8e-15 m.
  So one board square is exactly `checker_width` real units, and the unit is whatever
  `checker_width` was written in.
- **Which corner is the origin.** `ordering.jl` rendered the flat board as the baseline camera sees
  it and ran Fromage's own `_detect_corners` on it. The varied inputs:
  - camera azimuths 0, π/2, 3π/4, π
  - the board's long axis along Y, along X, and at 45°
  - both colour parities
  - `n_corners` given as `(10, 7)` and as `(7, 10)`
  - the `sar` values listed below

  The first corner was the **same physical corner** for every camera azimuth and every `sar`. It
  changed only with the board's colour pattern and with the order of `n_corners`. For example,
  long axis along Y, parity 0, `(10, 7)`: origin `(−0.120, +0.180)` and `e_i = −Ŷ`, `e_j = +X̂` at
  every azimuth. The board has 11 × 8 squares (10 × 7 inner corners), so its colour pattern is
  not symmetric under a 180° turn. **After the gauge none of this matters**: the translation and
  rotation absorb any choice of origin corner and in-plane axis direction. Only the handedness
  survives.

### Handedness

The gauge is a translation plus a rotation, with no reflection, so it **cannot undo a mirrored
board frame**. `s` in the formula is the handedness of the detected grid `(e_i, e_j)` against world
`(X, Y)`, which is the sign of `e_i × e_j`.

- **Synthetic check that the sign propagates.** `gauge.jl` builds the true camera for all 8 grid
  orderings: 4 have `s = +1` and 4 have `s = −1`. Fromage matches the formula with the matching
  `s` to 2e-14 m every time. A mirrored ordering does produce a mirrored real space: for example
  `(+0.30, 0) → (0, −0.30)` where the `s = +1` ordering gives `(0, +0.30)`.
- **What OpenCV actually returns.** `s = +1` in **every** detection: 48 of 48 through Fromage's own
  `_detect_corners` at `sar = 1`, and 178 of 178 through `findChessboardCorners` with Fromage's
  flags minus `CALIB_CB_FAST_CHECK` at sar 0.5, 10/11, 64/45 and 2 (`ordering_nofast.jl`). For a
  board lying face-up on the arena and seen from above, real space is not mirrored in any of these
  cases.

### Display to stored, at any `sar`

`center`/`north` are display `(x, y)`, and `to_stored` makes them stored `(row, col)`
(`src/spaces.jl:75-78`, with `stored_x(x, sar) = x / sar` at `:58`). The simulation must therefore
supply

```
center = (col · sar, row)      where (row, col) is the analytic STORED projection of C
north  = (col · sar, row)      likewise for N
```

using **the same pixel convention as the corners**. OpenCV's convention is 0-based, with pixel
centres on integers. That is the space `image2real` was fitted in, so a `center` in any other
convention shifts the gauge. Evidence from `convention.jl`: corners detected on a render (pixel
`(r, c)` centred at 0-based `(r−1, c−1)`) sit **0.16 px RMS** from the analytic 0-based
projection, against **1.4 px** from a 1-based one.

The round trip `to_stored((col·sar, row), sar)` returns `(row, col)` exactly at sar 0.5, 16/15, 2
and 1, and to within 1.1e-13 px at 10/11 and 64/45. With the true camera model the whole gauge
formula holds to 2e-14 m at every `sar` tested. **The gauge and `to_stored` are correct at
`sar ≠ 1`.**

The simulation's stored frames follow the map: `sar > 1` narrows the stored width, `sar < 1` the
stored height. In both cases Fromage's display units are `(col·sar, row)`. For `sar < 1` that is
the physical display scaled by `sar`, not the physical display itself. The formula above already
accounts for this: it is written in terms of the stored projection.

## What the simulation will see instead (not the gauge's fault)

1. **`sar ≠ 1` through the fitted model: #275.** `fitted.jl` feeds `_rectification` analytic
   corners (12 waved views plus the flat extrinsic board, as `Float32` like OpenCV's). At `sar = 1`
   the formula holds to **0.6–0.9 µm RMS** (max 2.8 µm) with `radial_parameters` 0 and 1, for both
   handedness signs. At `sar ≠ 1` the RMS error over the arena is:

   | sar | error over the arena |
   |---|---|
   | 10/11 | 7 mm |
   | 16/15 | 4.6 cm |
   | 0.5 | 5.9 cm |
   | 64/45 | 14 cm |
   | 2 | 14 cm |

   On the board's own footprint the error is 0.26–4.7 mm; points off the board are extrapolations.
   `fitted275.jl` repeats `_rectification`'s body verbatim except that `fit_model` receives `1/sar`.
   That brings every `sar` back to **≤ 2.2 µm RMS**, and the fitted `frow`/`fcol` match the truth
   exactly. For example, at sar 2 main fits `frow 2325.6, fcol 4651.1` where the truth is `900.0`
   and `450.0`. So the whole `sar ≠ 1` error is the known focal-ratio bug (#275,
   `detect_fit.jl:30`), not the gauge. Rung 1 of the map will therefore see a large,
   `sar`-dependent discrepancy until #275 is fixed.
2. **`CALIB_CB_FAST_CHECK` rejects the anamorphic flat board (#288).** Across 48 renders per `sar`,
   the counts are:

   | sar | detected by Fromage's `_detect_corners` | detected without `CALIB_CB_FAST_CHECK` |
   |---|---|---|
   | 1 | 48 | not run |
   | 10/11 | 48 | 48 |
   | 0.5 | 0 | 34 |
   | 64/45 | 0 | 48 |
   | 2 | 0 | 48 |

   Caveats: my board is small in the frame (about 230 × 120 display px of a 1920 × 1080 frame), and the
   render uses 3 × 3 supersampling, not the rig's 4 × 4. Whether the real baseline rig trips this
   is for the simulation to measure. It is flagged here because the map measures Fromage "as is,
   `CALIB_CB_FAST_CHECK` included".
3. **Integer `center`/`north` in `rectifications.csv`.** The gateway types them
   `NTuple{2, Int}` (`src/VerifyRectifications/types.jl:10-11`). Rounding the exact projections to
   whole display pixels costs **1.2 mm** of error at sar 1 and 2, and **1.9 mm** at sar 0.5, where
   the display units are half-size (`fitted.jl`, true camera). That error is a rigid translation
   plus rotation, and the map's Procrustes residual would separate it out. The builder-level rung
   can pass fractional pixels and see none of it.

## Not verified

- **`north = missing`**: the identity rotation there was read in the code, not run.
- **Boards whose colour pattern is symmetric under 180°** (both inner-corner counts of the same
  parity, e.g. 9 × 7): the origin corner may then depend on the view. That changes nothing after
  the gauge, but I did not test whether the handedness also stays fixed.
- **Boards seen from below**, or any view other than one looking down at a face-up board: the
  `s = +1` result is empirical, from 226 detections of one board design at azimuths 0–π and a 45°
  view. I did not find an OpenCV guarantee of handedness in its source or documentation, and I did
  not look for one beyond these runs.
- **The `matlab` path** shares `_maps` (`from_matlab.jl:84`) but has its own camera model, so its
  pre-gauge frame is not covered here.
- **`from_extrinsic`** (a single view with a fixed principal point) was not run separately. I expect,
  without having measured it, that the baseline rig's principal-point offset makes that fit wrong
  regardless of the gauge.
- **Lens distortion**: every run here has `k = 0`. The gauge is downstream of `inv_distort`, so the
  formula should carry over unchanged, but I did not test it.
