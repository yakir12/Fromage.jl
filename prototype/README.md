# Prototype: one simulated trial, end to end

**Throwaway code, captured as a primary source. This branch is never merged.**

It answers [#283](https://github.com/yakir12/Fromage.jl/issues/283), a ticket of the wayfinder map
[#280](https://github.com/yakir12/Fromage.jl/issues/280): can a pseudo-random synthetic trial measure
Fromage's rectification error against ground truth the package never touches? The results, with the
rendered frames, are at <https://claude.ai/artifact/VCv2y7v8X1ppxZqPskf3tX>.

The real module (`simulation/`, plus shared generators in `test/`) is specified by the map's
remaining tickets and built separately. Nothing here ships: there are no tests, no error handling,
and the detector was patched three times while the prototype ran.

## Running it

```sh
JULIA_NUM_THREADS=auto julia --project=test prototype/prototype_trial.jl 7 8 9
```

Each argument is a seed. Env knobs: `PROTO_MIN_FLAT` (how much of the frame the flat board must
cover, default `0.08`), `PROTO_DUMP=1` (write frames as PNGs), `PROTO_LIB=1` (include it as a
library instead of running it).

| file | what it is |
|---|---|
| `prototype_trial.jl` | the trial: draw, render, encode, build, detect, measure |
| `dump_scenes.jl` | render one seed's three kinds of frame as PNGs |
| `debug_target.jl` | render only the target frame and inspect the dots |
| `probe_detect.jl` | run `findChessboardCorners` over one frame with varying flags |
| `run5.log`, `run6.log`, `run10.log` | the three sweeps; `run10` is the one on the page |

## What it established

- **The instrument is sharper than what it measures.** Rendered checkerboard corners land within
  0.051–0.086 stored px of their true projections (#275's own bar was 0.11–0.23), and independent
  dot detection within 0.023–0.118 px.
- **The anamorphic bug (#275) dominates everything else**: 1.2–12.6 % error at `sar ≠ 1` against
  ≤ 0.035 cm for the identical trial at `sar = 1`. Seed 15 mismeasures 87.27 cm as 76.32 cm.
- **The one-pixel origin offset (#276) shows up at the right size**: 0.01–0.07 cm at `sar = 1`.
- **`CALIB_CB_FAST_CHECK` causes false negatives** on a small-but-visible flat board — found without
  the flag, missed with it, on the same frame.
- **Something else bites at narrow fields of view**: two square-pixel trials (87° and 70°) are ~20×
  worse than every other `sar = 1` result, where #275 cannot reach them.

## Three bugs worth not repeating

They were all in the prototype rather than the package, and each one failed silently:

1. **Raw video is row-major.** Writing a Julia matrix straight to ffmpeg encodes a transposed frame,
   and every detection then fails for a reason that looks like bad rendering.
2. **Draw order matters.** A dot outside the arena disc was painted over by the surround, because
   the arena bound was tested before the dots.
3. **The background is the arena floor, not the frame.** On a portrait frame the arena is a minority
   of the image, so a global median landed on the sky and the detection threshold collapsed to zero.
