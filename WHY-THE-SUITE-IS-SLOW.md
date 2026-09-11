# Why the suite is slow

A full accounting of where `Pkg.test()`'s wall clock goes, measured 2026-09-11, and of what
cutting tests would and would not buy. **Nothing here was acted on.** The candidate cuts came to
about 17 seconds of a 373-second suite, which was judged not worth disturbing tests that have
caught real defects. The measurements are kept so the next person asking "can the suite be made
faster by removing tests?" gets an answer instead of a week.

It sits beside `CIFS-SHARE-INVESTIGATION.md` and `WHY-FRAMES-FAIL.md` for the same reason they
do: it is a long-form measurement with no single line of code to sit beside.

Read the short version in `DECISIONS.md`, "Cutting the test suite was measured and declined".

---

## The bottom line

**Roughly 47% of the suite's clock is Julia's first-call compilation, not test execution.** That
single fact decides everything else, because it inverts the intuition that expensive tests are
the ones worth removing:

- Deleting a **redundant** test recovers only the work it does — about **0.06 s** for a gateway
  scenario, **0.6 s** for a tracking case. Its code paths are compiled by whatever else covers
  them, so the compile share is not recovered at all.
- Deleting a **non-redundant** test costs about **0.25 s** in the gateway suites, because it is
  the only thing that compiles the package branch it exercises.

So the tests that are cheap to remove are the ones you do not want to remove, and the ones that
are expensive to remove are the ones you cannot. What is left is a short list of testsets that
spend real seconds *doing* something, and that list is much shorter than the file sizes suggest.

---

## How this was measured

Everything below was run on one machine (x86_64 linux, warm depot), under

```sh
JULIA_NUM_THREADS=auto julia +1.13 --project=test <script>
```

with three scaffolds, all of them scratch files that were deleted afterwards:

1. **Per-file totals** — an instrumented mirror of `test/runtests.jl`: the same includes in the
   same order, each wrapped in `@elapsed`.
2. **The work/compile split** — a second run that includes every file *twice* in one process.
   Pass 2 does identical work with nothing left to compile, so `pass 1 − pass 2` is the
   compilation. Julia allows module redefinition, so the module-wrapped suites re-include fine.
3. **Per-testset and per-unit costs** — Julia 1.13's own `@testset verbose = true` summary prints
   a Time column; unit costs are one warm call followed by one timed call.

**`@timed`'s `compile_time` is unusable here** and was discarded: under multiple threads it sums
compilation across them, and for `test/jet.jl` it reported 119.5 s of "compile" inside a 31.3 s
wall clock. The two-pass split is what every figure below uses.

`DECISIONS.md` is right that wall clock on this machine cannot carry a fine-grained claim. These
numbers are good to roughly ±10% and are for **ranking**, not for tracking; nothing here should
be pinned to a version or checked in CI.

---

## The split, file by file

Include order as `runtests.jl` has it. `work` is the second in-process pass; `compile` is the
difference.

| file | total (s) | compile (s) | work (s) |
|---|---:|---:|---:|
| `verifyrectifications.jl` | 119.6 | ~92 | ~28 |
| `fromage.jl` | 53.6 | ~13 | 40.2 |
| `verifyruns.jl` | 40.3 | ~13 | 27.8 |
| `quality.jl` | 33.1 | ~10 | ~23 |
| `jet.jl` | 31.3 | ~13 | 18.3 |
| `pawsometracker.jl` | 23.7 | ~8 | 15.4 |
| `rectifications.jl` | 17.7 | ~12 | 5.5 |
| `apriltag_pipeline.jl` | 16.1 | ~3 | 12.9 |
| `fixtures.jl` + `harness.jl` | 10.1 | 1.2 | 8.9 |
| `shareio.jl` | 7.7 | 0.6 | 7.1 |
| `probing.jl` | 5.8 | 0.7 | 5.1 |
| `apriltag.jl` | 5.3 | 2.6 | 2.7 |
| `gateway.jl` | 2.7 | 1.4 | 1.3 |
| `spaces.jl` | 1.1 | 0.1 | 1.0 |
| `parsing.jl` | 0.7 | 0.6 | 0.1 |
| **total** | **368.8** | **~172** | **~197** |

**Per-file totals are positional, and the work column is not.** `verifyrectifications.jl` carries
~92 s of compile largely because it is the first file to drive the full gateway → video read →
OpenCV corner detection → rectification build path; whichever file went first would pay most of
it. In the two-pass run, where the order differed, `fromage.jl` paid 73 s instead of 53 s.

**The work column is a floor.** Pass 2 reuses every specialisation pass 1 built, including some a
fresh process would rebuild. A test's real cost sits between its work figure and its total.

### The evidence for the split

```
test/VerifyRectifications/test_parsing.jl   pass 1  53.45 s   pass 2  4.63 s
```

48.8 s of that 53 s is compilation. The whole of `test_parsing.jl` is scenarios that fail at the
parse tier and never reach a video — a parse-failure scenario costs 0.079 s against 0.204 s for
one that detects corners — so its 53 s was never the cost of what it tests.

Dropping whole files from `VerifyRectifications` prices an assertion directly:

| | total | assertions |
|---|---:|---:|
| full suite | 121.9 s | 458 |
| − `test_parsing.jl` | 91.2 s | 381 |
| − `test_parsing` + `test_structural` + `test_values` | 75.5 s | 276 |

≈ **0.25 s per gateway assertion, of which only ~0.06 s is work.** Removing 40% of the assertions
recovered 38% of the time — near-linear, because each assertion compiles a package branch the
others do not.

---

## Where the work actually sits

Only a dozen items spend more than five seconds doing something. Ranked by measured work:

| component | work | what only it buys |
|---|---:|---|
| `fromage.jl` — AprilTag registered stack, large pan | 18.2 s | Rolling phase of the *registered* stack, backfilled pre-seed registrations, tag loss → `missing` |
| `JET.test_package` | 16.0 s | Undefined bindings and method errors across every submodule |
| `Aqua.test_stale_deps` | 11.5 s | A dep in `Project.toml` that is never loaded |
| `fromage.jl` — multi-run, mixed calibrations | 9.9 s | Fixed canvas across mixed source resolutions; PTS/DTS across concat joins |
| `fromage.jl` — AprilTag drone tracking e2e | 9.8 s | The only `type = apriltag` row driven through `main` |
| `apriltag_pipeline.jl` — 7 × `check_flight` | 8.1 s | Registration inverts each drone degree of freedom |
| `ExplicitImports.check_no_implicit_imports` | 5.2 s | A bare `using` anywhere in the package |
| `pawsometracker.jl` — long-stationary target | 3.7 s | `protect_target`: the model must not absorb a paused disc |
| `jet.jl` — 7 × `@test_opt` | 2.3 s | No runtime dispatch on the lens and AprilTag hot paths |
| `Rect/test_frame_reads.jl` — 64 concurrent reads | 2.1 s | Concurrent `_frame_at` returns the lone reader's bytes |

### Unit costs, for turning a count into seconds

| operation | cost |
|---|---:|
| `make_target_video`, default (100×100, 50 frames) | 0.08 s |
| `make_target_video`, `nsegments = 3` | 0.08 s |
| `make_target_video`, `duration = 30` + pause (750 frames) | 0.50 s |
| `make_video`, 5 s 640×480 testsrc | 0.39 s |
| `track1` on a 50-frame target video | 0.64 s |
| `track1` on the 750-frame paused fixture | 3.23 s |
| `make_apriltag_video`, 40 frames (480×480) | 0.20 s |
| `make_apriltag_video`, 300 frames | 1.06 s |
| `ApriltagRectification` (reference space build) | 0.14 s |
| `track1` apriltag, 40 frames | 0.76 s |
| `registration_trace`, 40 frames (re-render + detect) | 0.20 s |
| one full `check_flight` | 1.15 s |
| gateway `check`, `uniformrow` / `matlabrow` | 0.070 / 0.066 s |
| gateway `check`, `checkerboardrow` / `mixedrow` / `apriltagrow` | 0.204 / 0.211 / 0.179 s |
| gateway `check`, a row that fails at the parse tier | 0.079 s |
| `parse_rectifications` alone, no verification tiers | 0.048 s |

The gateway progress meters cost nothing measurable: `check_rectifications` with
`progress = false` timed 0.206 s against 0.204 s with it on.

---

## Overlaps found

Four, and only the first is worth anything.

**1. Four tracking cases run twice.** The frame-centre default, the lighter target,
`sample_fps = 12.5` and the segmented run are asserted in `test/pawsometracker.jl` against `track`
and again in `test/VerifyRuns/test_tracking.jl` through the gateway. Since `track` takes no
keyword arguments and `test/fixtures.jl`'s `track1` builds its `Tuning` through the same
`get_window` the gateway calls, the two produce the same coordinates by construction. The gateway
copy adds the csv → `Tuning` hop, which `test_values.jl` and `test_defaults.jl` already pin
without decoding a video. **~2.7 s** (4 × 0.68 s).

What would have to stay in `test_tracking.jl`: the `center` keyword, `window_size` from a csv
cell, the start/stop sub-window, both downscale cases and the anamorphic pair — those exercise
gateway-side conversions with no counterpart in the direct suite.

**2. Six target-video fixtures built twice.** `pt_base/light/seg/sar05/sar2` and
`t_base/light/sar05/sar2/seg/seg2` are the same generator calls into two `DATADIR`s. Genuinely
the same bytes, and worth **~0.4 s** — which is the arithmetic "Fixture encoding is not what
makes the suite slow" already did, confirmed.

**3. Four single-axis AprilTag flights.** Scale, yaw, pitch+roll and skew each fly one degree of
freedom; `all6dof` flies five of them together on mutually prime periods and asserts the same two
contracts at the same tolerances, so a regression in any one axis fails it too. **~4.6 s.** What
is lost is the failing testset's *name* — a debugging affordance the file states outright
("Isolated on purpose: if one of these regresses, the failing testset names the axis"). Skew is
the exception worth keeping separate: it is not a drone degree of freedom, so `all6dof` does not
carry it.

**4. The AprilTag e2e and stage 4 overlap, and both should stay.** `fromage.jl`'s drone e2e is
the only AprilTag row that goes through `main`, the csv, the track csv and the diagnostic; stage
4 adds the identity-registration assertion at `1e-6`, which the e2e cannot make.

---

## Measured and refuted

The most useful part of this file. Each of these looks obviously right and is not.

### Funnelling the test helpers' keyword overrides into a `Dict`

Every gateway scenario passes a distinct keyword signature through `runrow` → `_merge` → `row` →
`buildrow`, and each distinct signature is a new `NamedTuple` type and therefore a new
specialisation of the whole chain. An isolated benchmark of 20 scenarios said 11.58 s → 1.15 s, a
10× win with no test changed and no call site rewritten.

`test/harness.jl` and both `helpers.jl` were patched to convert at the first boundary and both
gateway suites run for real:

```
baseline              159.9 s
with the Dict change  158.4 s
```

**No effect.** The isolated benchmark was an ordering artefact — the first block compiled the
package's per-column verification branches and the second reused them, so it measured the order,
not the change. The cost is in those package branches, not in the test-side plumbing. The patch
was reverted.

The lesson generalises to anything else measured this way: when two variants run in one process,
the second one is warm. Randomise the order or use separate processes.

### Warming the gateway with one representative call

If `verifyrectifications.jl`'s ~92 s of compile were one shared pipeline, one successful pass
through it would absorb the lot. Running all four row types plus a parse failure and a strict
load first, using the helper's *exact* keyword signature:

```
cold                              122.7 s
warm-up 20.7 s + suite 104.4 s    125.1 s
```

**Net worse.** The compile cost is spread across hundreds of distinct package branches, one per
column and failure mode, and no single warm-up reaches them. This is also why extending the
precompile workloads (see below) is filed as speculative rather than obvious.

### Shrinking the bigpan flight

The cheap-looking version of the one recommendation that did survive: shorten the flight *and*
the background window together.

```
nframes=300  bl=250   21.1 s   straightness 0.1149  (bound 0.5)  pass
nframes=100  bl= 50    1.5 s   straightness 0.8979  (bound 0.5)  FAIL
```

The flight length is load-bearing for the tolerance; the background window is not. That
distinction is the whole content of the next section, and it only appeared because the shortcut
was tried first.

---

## The candidate cuts, and what each was worth

Recorded with their measurements so the decision can be revisited without re-measuring. **None of
these were applied.**

### Shorten the bigpan flight's background window — the only large one (~13 s)

`test/fromage.jl`'s *AprilTag: registered stack survives a large pan* testset spends 18.2 s in
`track1` alone — 5% of the suite and 9% of its work, from one testset. The cost is the 250-slice
registered stack, not the 300-frame flight. Sweeping `background_length` on the **unchanged**
fixture, with the same occlusions and the same assertions:

| nframes | background_length | track | missing indices | displacement | straightness |
|---:|---:|---:|---|---:|---:|
| 300 | 250 (default) | 18.18 s | exact | 0.0004 | 0.1149 |
| 300 | 150 | 11.19 s | exact | 0.0004 | 0.1149 |
| 300 | 100 | 7.90 s | exact | 0.0004 | 0.1149 |
| 300 | 60 | 4.98 s | exact | 0.0004 | 0.1149 |
| 300 | 30 | 2.95 s | exact | 0.0218 | 0.3158 |

Down to 60 the tracked output is **identical to four decimals** — same missing indices, same
displacement, same straightness. A 60-slice stack also exercises the rolling phase *harder*: 240
rolling frames instead of 50, which is what the testset says it is for. Below 60 it degrades
(still inside both bounds at 30, but no longer bit-identical).

What it would give up, stated plainly: the *registered* stack would no longer be exercised at the
shipped default of 250. The plain stack still would be, by the 750-frame paused fixture in
`pawsometracker.jl`. `bl = 100` is the conservative version and still returns 10.3 s.

### The rest

| candidate | worth | what it costs |
|---|---:|---|
| Delete the four duplicated tracking cases (overlap 1) | ~2.7 s | Nothing, if `test_values.jl`/`test_defaults.jl` keep pinning the csv → `Tuning` hop |
| Drop `registration_trace` from the four flights that do not assert against it | ~0.8 s | The stationary flight and the two `teeth = true` flights need it; the others assert what the track already shows |
| Collapse the four single-axis flights into `all6dof` (overlap 3) | ~4.6 s | The failing testset stops naming the axis |
| Move `Aqua.test_stale_deps` to its own non-gating run | ~11.5 s | A check that blocks nothing has to be read, and nobody reads it — the same objection `DECISIONS.md` raises for the persistent-task split, minus the network flakiness |
| Trim the mixed-calibration diagnostic from 4 runs to 3 | ~2.5 s | The shared-rectification claim would have to move elsewhere; this testset has caught real concat faults |

`Aqua.test_stale_deps` is the one standalone surprise: at 11.52 s it costs more than the other
eleven Aqua and ExplicitImports checks combined (11.22 s), because it spawns a subprocess that
loads the whole package.

| check | cost |
|---|---:|
| `Aqua.test_stale_deps` | 11.52 s |
| `check_no_implicit_imports` | 5.18 s |
| `Aqua.test_undocumented_names` | 2.07 s |
| `check_no_stale_explicit_imports` | 1.95 s |
| `check_all_qualified_accesses_via_owners` | 0.96 s |
| the remaining six together | 1.06 s |

And JET's two halves, for completeness: `JET.test_package` 15.96 s, the seven `@test_opt` calls
2.30 s.

---

## What this review did **not** find

Worth recording, because "we looked and there was nothing" is a result:

- **No unused fixture, no dead test file, no dataset kept only because it exists.** Every
  generator in `test/fixtures.jl` has live callers; `make_corrupt_video` is shared by four sites,
  which is the deduplication `DECISIONS.md` already describes.
- **No combinatorial explosion.** The three loops that look like matrices — `sample_fps` over
  five rates, diagnostic fps over four, the two anamorphic directions — each cover a distinct
  documented failure (#15, #17, #55, #36) and cost under a second apiece.
- **No duplicated scenario in either gateway table.** They are one assertion per column or rule,
  each pinning a message nothing else pins. This is what "Scenario csv names are generated, not
  invented" describes from the other side.
- **Fixture generation is still not the cost.** The whole generator set is ~2.5 s, unchanged from
  the measurement in "Fixture encoding is not what makes the suite slow".
- **The progress meters are not the cost** (0.206 s vs 0.204 s per scenario).

## One thing that was not chased

Both gateway precompile workloads point at nonexistent files, so they compile the parse and
first-tier path and stop. Everything after a successful probe — `read_video_metadata!`,
`verify_extrinsics!` with real corner detection, `verify_intrinsics!`, the builders — compiles for
the first time inside the test suite, and that is where the ~92 s lives.

Extending a workload to run against a small bundled clip is *feasible* — `FFMPEG` and
`RelocatableFolders` are already dependencies — but the warm-up experiment above is the reason it
is not obviously worth it: one representative successful pass absorbed only ~10 s. A workload
would have to cover all four row types, clean and flagged, to move materially more, and it would
make precompilation slower and more fragile (spawning ffmpeg at build time is a known hazard in
sandboxed environments). Anyone trying it should measure against the numbers in this file rather
than against intuition.
