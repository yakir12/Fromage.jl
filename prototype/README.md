# Prototype: the baseline rig through the builders

**Throwaway code, captured as a primary source. This branch is never merged.**

It answers [#291](https://github.com/yakir12/Fromage.jl/issues/291), a ticket of the wayfinder map
[#289](https://github.com/yakir12/Fromage.jl/issues/289): does the baseline rig work end to end
through `from_checkerboard` and `from_extrinsic`, and what does it measure? Everything was run on
`main` at `057a261` (v0.6.1), Julia 1.13.0, 32 threads.

## Running it

```sh
JULIA_NUM_THREADS=auto RIG_OUT=<folder> julia --project=test prototype/baseline_rig.jl
JULIA_NUM_THREADS=auto RIG_OUT=<same folder> julia --project=test prototype/probe_extrinsic.jl
```

The knobs are read from the environment:

- `RIG_F`, `RIG_CX`, `RIG_CY`: the intrinsics, in display px, 0-based;
- `RIG_K1`, `RIG_SAR`, `RIG_SS`: the lens, the sample aspect ratio, the supersampling;
- `RIG_CORNER_FRAC`, `RIG_CORNER_TILT`: the corner poses' size (as a share of the frame width) and tilt.

The rig renders in about 4 s. Most of each run is spent reading frames through ffmpeg.

| file | what it is |
|---|---|
| `baseline_rig.jl` | the rig: render, encode, detect, build, measure |
| `probe_extrinsic.jl` | the extrinsic-only fit on detected, analytic, and noisy analytic corners |
| `run_corner_third.log`, `run_corner_quarter.log`, `run_corner_fifth.log` | full runs with the corner poses at ⅓, ¼ and ⅕ of the frame width |
| `probe_extrinsic.log` | the probe's output |
| `frames/` | PNGs of some frames (the `⅕` run) |

## What it established

See the resolution comment on #291.
