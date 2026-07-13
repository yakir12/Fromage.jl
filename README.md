# Fromage 🧀

[![Docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://yakir12.github.io/Fromage.jl/stable/)
[![Test workflow status](https://github.com/yakir12/Fromage.jl/actions/workflows/Test.yml/badge.svg?branch=main)](https://github.com/yakir12/Fromage.jl/actions/workflows/Test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/yakir12/Fromage.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/yakir12/Fromage.jl)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![BestieTemplate](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/JuliaBesties/BestieTemplate.jl/main/docs/src/assets/badge.json)](https://github.com/JuliaBesties/BestieTemplate.jl)
[![](https://img.shields.io/badge/%F0%9F%9B%A9%EF%B8%8F_tested_with-JET.jl-233f9a)](https://github.com/aviatesk/JET.jl)

This is the main package used to organise, calibrate, and track video files in the Dacke lab. You film **runs** (an animal moving through an arena) and **calibrations** (a checkerboard in that same arena); Fromage tracks the target in every run and converts the tracks into real-world coordinates (e.g. cm on the arena floor), plus a diagnostic video to check that the tracker followed the right thing.

## 📖 Documentation

**Everything — installation, preparing your files, running, troubleshooting — lives at
[yakir12.github.io/Fromage.jl](https://yakir12.github.io/Fromage.jl/stable/).** Start there.

## Install

With Julia ≥ 1.11, in Pkg mode (type `]` at the REPL):

```
pkg> add https://github.com/yakir12/Fromage.jl
```

> [!NOTE]
> On Apple Silicon Macs the AprilTag functionality (drone tracking) doesn't run natively — see
> [the docs](https://yakir12.github.io/Fromage.jl/stable/help#Macs) for details and the workaround.

## Development

Releases are automatic: every push to `main` that passes CI is patch-bumped, tagged, and
released, and the stable docs advance with it. Put `#minor` or `#major` in the commit message
to bump more than a patch. There is nothing to do manually — see [RELEASING.md](RELEASING.md)
for how it works, the commit-message rules, and recovery procedures.

Run the tests with:

```sh
JULIA_NUM_THREADS=auto julia --project -e 'using Pkg; Pkg.test()'
```

Each former package's tests run in their own wrapper module (`test/rectifications.jl`,
`test/pawsometracker.jl`, `test/verifyrectifications.jl`, `test/verifyruns.jl`), plus unit tests
for the shared csv-cell machinery (`test/parsing.jl`), package-wide quality checks
(`test/quality.jl`) and an end-to-end `main` run over a synthetic data folder (`test/fromage.jl`).
Setting `JULIA_NUM_THREADS` exercises the threaded code paths — frame reading, corner detection,
tracking — with real parallelism.

To build the documentation locally:

```sh
julia --project=docs docs/make.jl
```
