# Supersampling convergence (#292)

**Throwaway measurement, captured as a primary source. This branch is never merged.**

Answers [#292](https://github.com/yakir12/Fromage.jl/issues/292) on the wayfinder map
[#289](https://github.com/yakir12/Fromage.jl/issues/289): has the ideal sensor's 4×4 supersampling
converged? Renders the frozen pose set (±60° about e2, ±50° about e1, corner poses at ⅕, the flat board)
with `../baseline_rig.jl` at 4×4, 8×8, 16×16 and 32×32, for sar 1, 64/45 and 2. Run on `main` at `057a261`
(v0.6.1), Julia 1.13.0, 32 threads.

```sh
# one configuration per process: SS and SAR are constants of the rig
JULIA_NUM_THREADS=auto RIG_SAR=64/45 RIG_SS=16 RIG_CORNER_FRAC=0.2 SS_OUT=out/sar64_45_ss16.jls \
  julia --project=test prototype/supersampling/ss_run.jl
julia --project=test prototype/supersampling/ss_compare.jl                   # reads ./out next to it
RIG_SAR=1 SARTAG=1 RIG_CORNER_FRAC=0.2 julia --project=test prototype/supersampling/ss_detail.jl
```

`compare.log` is the output. At sar ≠ 1 the intrinsics are refitted with `aspect = 1/sar`, so #275
stays out of the measurement.
