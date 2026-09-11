# Fromage 🧀

[![Docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://yakir12.github.io/Fromage.jl/stable/)
[![Test workflow status](https://github.com/yakir12/Fromage.jl/actions/workflows/Test.yml/badge.svg?branch=main)](https://github.com/yakir12/Fromage.jl/actions/workflows/Test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/yakir12/Fromage.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/yakir12/Fromage.jl)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![BestieTemplate](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/JuliaBesties/BestieTemplate.jl/main/docs/src/assets/badge.json)](https://github.com/JuliaBesties/BestieTemplate.jl)
[![](https://img.shields.io/badge/%F0%9F%9B%A9%EF%B8%8F_tested_with-JET.jl-233f9a)](https://github.com/aviatesk/JET.jl)

This is the main package used to organise, calibrate, and track video files in the Dacke lab. You film **runs** (an animal moving through an arena) and **rectifications** (a checkerboard in that same arena); Fromage tracks the target in every run and converts the tracks into real-world coordinates (e.g. cm on the arena floor), plus a diagnostic video to check that the tracker followed the right thing.

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

Comments in `src/` and `test/` describe what the code does now. [CONTEXT.md](CONTEXT.md) is the
domain model — what a run, a rectification, a frame and a space are, and the rules that decide a
name. The reasoning behind the non-obvious choices — the alternatives that were tried, and the bugs
that ruled them out — lives in [DECISIONS.md](DECISIONS.md); read that before removing anything that
looks gratuitously complicated, because it is usually load-bearing.

Releases are automatic: every push to `main` that passes CI is patch-bumped, tagged, and
released, and the stable docs advance with it. Put `#minor` or `#major` in the commit message
to bump more than a patch. There is nothing to do manually — see [RELEASING.md](RELEASING.md)
for how it works, the commit-message rules, and recovery procedures.

One exception: a push that touches *only* files which cannot affect the package — the
top-level `*.md` files, `LICENSE`, `.gitignore`, `codecov.yml`, `.lychee.toml`,
`.copier-answers.yml` — does not run the test workflow, and so is not released. Anything
under `src/` or `docs/` does trigger a release, so the published documentation still keeps
up with the code.

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

That command needs no network once the dependencies are installed. One check is different: Aqua's
persistent-task check builds a temporary environment around the package and asks Pkg to resolve it,
so it reaches for the registry on every run. Offline it usually still passes, with a warning, and
hard-fails only on a depot holding no registry at all — where `Pkg.test()` would have failed first
anyway. That conditional dependency on an outside service is why it runs on its own:

```sh
julia --project=test test/persistent_tasks.jl
```

On CI it is its own workflow, `Persistent tasks`, which deliberately does not gate a release: an
unreachable GitHub shows up as that check going red, and nothing else.

To build the documentation locally:

```sh
julia --project=docs docs/make.jl
```
