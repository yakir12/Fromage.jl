# Decisions

**Read this before removing something.**

`CONTEXT.md` says what the package *is* and what its words mean. `src/` and `test/` comments say
what the code *does*. This file holds the third thing neither can: **what was tried, measured, and
not kept** — and the hazards that have no line of code to hang a comment on.

That is the irreducible part. You cannot write a comment on a parallel layer that was removed, or
on a polynomial root-finder that was benchmarked and declined. Without this file someone re-adds
them and re-derives the measurement. It has already happened once: a rename's reasoning lived only
in a commit message, so it got half-applied and cost three rounds to reconstruct.

So the test for an entry here is: **would a reasonable person otherwise undo this, or redo the thing
we rejected?** If the answer is no — if it merely describes how something works — it belongs in a
code comment, and if it names something it belongs in `CONTEXT.md`.

Entries cite the issue number where one exists (`#nn` → `github.com/yakir12/Fromage.jl/issues/nn`);
`git log --grep '#nn'` finds the commit.

---

## Pipeline

### The diagnostic video is concatenated with ffmpeg's concat demuxer

`main` writes one diagnostic segment per run and stream-copies them into a single
`results_dir/diagnostic.mp4`. This works only because every segment shares one resolution, codec
and quality — which is why `DIAGNOSTIC_SIZE` is a fixed square canvas and every writer uses the
same encoder settings, rather than each rectification rendering at its own natural size.

It used to be a pairwise tree of `concat:`-protocol calls with per-join discontinuity heuristics,
run at `-loglevel 8` so that every warning it produced was hidden. The demuxer rewrites timestamps
monotonically by design, so the heuristics went away with it.

### An unmatched `run_ids` / `rectification_ids` filter is an error (#21)

Filtering by id is a convenience for iterating on one run, so an id that matches nothing is a
typo, not a request for less work. Unchecked, it failed twice over: a *total* miss emptied the
pipeline and only surfaced at the very end, when `concatenate` handed ffmpeg a zero-entry list and
ffmpeg reported "Invalid data found when processing input" — which points at the footage rather
than at the filter. A *partial* miss was quieter and worse: fewer runs were processed than asked
for, with no error at all. Hence the strict rule that every requested id must match.

### Diagnostic playback speed is derived from the effective frame rate (#55)

`fps` in `runs.csv` is a request. The sampler advances whole frames, so the only rates it can
actually deliver are `vid_fps / skip`. The diagnostic writer originally declared its playback
speed from the *requested* rate, which made a 20 fps request on 30 fps footage claim 2.67× real
time. Both the sampler and the writer now derive from `frame_skip`/`effective_fps`, and keeping
one definition is what stops them drifting apart again.

Before that, the writer's framerate was left at VideoIO's default 24 while every tracked frame was
written, so a 50 fps track played back at 0.48× speed. Hence `DIAGNOSTIC_SPEEDUP`/`DIAGNOSTIC_FPS`
and the frame decimation.

### `only_track` names its diagnostics by `run_id` (#68)

It used to name them by loop index — `1.mp4`, `2.mp4` — while `main` named the same files by
`run_id`. The two agree only when the csv names no runs, because `resolve_run_ids!` then imputes
the row number as the id. As soon as a csv names its runs, or `run_ids` filters one out, the index
no longer matches any row the user is looking at: asking for run `r5` alone wrote `1.mp4`.

The duplication is what let the two drift. `main`, `only_track` and `only_rectify` now open through
the same two functions — `gather_rectifications` and `gather_runs`, each making the results
directory, loading the csv the caller named, and applying the id filter — so there is one place for
that opening to be right.

### Diagnostics are `.mp4`, not `.ts`

The old `.ts` segments defaulted to MPEG-2 at libavcodec's default *average* bitrate — constant
bits per second, which turned to mush as the tracking fps rose. `.mp4` selects H.264, whose `crf`
option gives constant quality instead.

---

## Concurrency

### Reads through a share fail on the share's schedule, not on ours (#68)

There used to be a global limiter here — `READ_SEM`, `set_read_limit!`, `read_limit`, an
`__init__` and a `RECTIFICATIONS_READ_LIMIT` environment variable — bounding simultaneous ffmpeg
opens on the stated grounds that "a burst of nested `tmap` tasks otherwise trips EAGAIN". It was
measured against the real share and deleted. The premise was false: failures do not scale with
how many reads are in flight. Sweeping concurrency 1 → 4 → 12 → 48 in interleaved rounds gave
**5,371 reads and zero failures at every level**, while a *completely idle* minute of the same
mount logged two session reconnects — the highest reconnect rate of any arm in the experiment.
Capping concurrency bought nothing and cost ~5% on the stage it guarded.

What does fail is an `open()` that is in flight when the mount reconnects. Captured verbatim:
ffmpeg exits 245 (`AVERROR(EAGAIN)`, i.e. errno 11) with `Error opening input: Resource
temporarily unavailable`, having hung 5–15 s first and delivered zero bytes; neighbouring
failures carry ECONNABORTED (exit 153) and EBADF (exit 247). No read ever dies part-way through —
the failures are entirely in the open. The mount is `soft`, which is precisely the option that
tells the cifs client to hand a reconnect to userspace as EAGAIN instead of reissuing the request
itself the way `hard` would; the failures arrive in bursts across unrelated files because one
reconnect kills everything open at that instant.

This is also why tracking never sees it while doing a hundred times the I/O: `open_gray_video`
opens each video once, under a lock, and streams from the established handle, at roughly 0.6
opens/s. Rectification opens once per *frame*, concurrently, at ~10 opens/s. The exposure is the
open, not the bytes.

### One module owns every retry (#68)

`ShareIO` is the only place in the package that retries anything, and the only place that decides
what "transient" means. It is included first, because all three paths that open the share depend
on it.

There used to be one retry, on the frame reads, and it covered the *smallest* of the three:

| path | opens per run | before | now |
|---|---|---|---|
| rectification frame reads | ~195 | 4 tries | `ShareIO.capture` |
| ffprobe probes (both gateways) | ~386 | **none** | `ShareIO.capture` |
| VideoIO tracking opens | ~372 | **none** | `ShareIO.withretry` |

The two subprocess paths were the same operation written twice — run a command against the share,
drain both pipes, classify the failure by its exit code — so they collapsed into one `capture`, and
the near-duplicate stderr cleaners in `Rectifications` and `Probing` became one `first_line`.

VideoIO gets `withretry` with a widened predicate rather than `capture`, because it reports an
unreadable file, a share failure and a seek past the end alike as a bare `ErrorException`; there is
no exit code to inspect. The price is that a genuinely broken file is opened three more times before
failing, which is cheap and is stated where it happens. The lock is taken *inside* the retried
closure so the backoff never sleeps holding it.

`main.jl`'s concat is deliberately left alone: every path it touches is under `results_dir` on local
disk. The retries are for the share and belong only on reads that cross it.

**The module is built to be deleted.** It compensates for a mount, not for anything in this package.
If the share is ever made reliable, the retries become dead code and one file goes away in one
piece — which is the whole reason it is one piece.

`_read_frame` therefore keeps its exponential backoff, and keeps it for a reason that is now
written down rather than assumed. It is not a concurrency guard; it covers reconnect windows.

It is also not the constant crutch it was taken for. Over a 3.5-hour paired soak — 407,160 reads
across four arms, 23 reconnects — there were **zero failures, and the loop fired zero times**. The
"~7% of stages abort without it" figure from CIFS-SHARE-INVESTIGATION.md is not a rate; the same
measurement repeated here gave 0 aborts in 522 iterations. What the retry covers is rare and
severe: one episode failed 62 of 195 reads inside 19 seconds. So it costs nothing in the normal
case and is decisive in the abnormal one, which is why it stays. It can be deleted for good only by
fixing the mount (see WHY-FRAMES-FAIL.md) — a `hard` mount would make the kernel do this retrying,
invisibly and correctly.

**If the threading is ever flattened to one level per stage, the semaphore becomes an ordinary
`tmap(...; ntasks = n)` and can go away — but measure against the real share, not the test
suite.**

### The innermost parallel layer is gone (#68)

`detect` filtered its search window with `imfilter!(CPUThreads(Algorithm.FIR()), …)` — the
innermost of five nested layers of parallelism, threading a 21×21 output window against a 29×29
kernel. It is `CPU1` now.

The benchmark harness priced it first: 281.6 µs threaded against 284.2 µs serial **on 32 threads**
— within 1%, because there is not enough work in one window to pay for the split. End to end, over
100 interleaved samples per arm, `track` on the shared fixture came out at min 108.8 / p25 111.4 ms
threaded against min 108.4 / p25 111.7 ms serial: indistinguishable. (Sequential A-then-B runs made
the serial arm look 21% slower; interleaving the rounds showed that was load on the machine, not
the change. Identical minima with divergent upper quantiles is what that always looks like.)

The results are **bitwise identical**, not merely close: `CPU1(FIR)` and `CPUThreads(FIR)` produce
the same `Float64`s from the same window, and 200 tracked coordinates across four scenarios —
explicit start, frame-centre search, `background_length = 0`, and a three-segment run — compare
equal bit for bit against the previous revision.

The resource argument cannot simply be dropped: `imfilter!` has no method taking `inds` without
one, so `ComputationalResources` remains a dependency.

This removes one layer. The other four — `tmap` over runs, `Threads.@spawn` for intrinsics, `tmap`
over intrinsic timestamps, and the `tmap` pairs in verification — still nest. They no longer need
a global limiter above them: `READ_SEM` was measured against the real share and deleted (see
"Reads through a share fail on the share's schedule, not on ours").

### ffmpeg commands bake their environment into the `Cmd`

Commands interpolate the *called* `FFMPEG.ffmpeg()` / `FFMPEG.ffprobe()` (the non-do-block form),
each of which returns a `Cmd` with the absolute executable path and an adjusted
`PATH`/`LD_LIBRARY_PATH` baked in via `setenv`; that environment survives interpolation into the
surrounding `Cmd`.

The deprecated `ffmpeg() do ... end` form mutates the process-global `ENV` instead. Under nested
`tmap` concurrency that raced: `LD_LIBRARY_PATH` grew without bound until a spawn died with
`E2BIG`. The snapshot/`addenv` machinery that worked around it is gone.

### `VideoIO.openvideo` is not thread-safe

Concurrent opens race — badly so on a cold network share, where the open path is slow enough to
widen the window — and the symptom is silently garbled or simply wrong frames, not an error.
Decoding independent streams *is* safe, so `OPENVIDEO_LOCK` serializes only the open. The open is
fast; the decode that follows stays concurrent.

### The AprilTag C detector is not reentrant

`apriltag_detector_detect` has global/static state that concurrent calls corrupt, and under enough
pressure it segfaults. This was verified three ways — fresh-per-task detectors, pre-created
per-frame detectors, and pooled-per-thread detectors all fail concurrently, while serial detection
is clean. Every detection call therefore goes through `APRILTAG_LOCK`. Reads and decoding stay
concurrent; only the (comparatively cheap) detect is serial.

Reference-frame building serializes the whole read + detect, because it also faces the one-shot
`VideoIO` read race above. It is one-time setup over a handful of calibrations, so the cost is
negligible.

---

## Coordinate spaces

### The axis-order conversions moved to `Spaces`, and three things deliberately did not

`stored x = display x / sar` had four independent spellings — `Rectifications.fix_coordinate`,
`PawsomeTracker.get_guess`, and two inside `apriltag.jl` — and #130 was two of them disagreeing
about which direction `sar` goes, which displaced every anamorphic rectification by half a frame.
The frame centre had two spellings. All of it is now `src/spaces.jl`: `stored_x`, `to_stored`,
`display_center_x`, plus the `RowCol` alias, which had been living in `Rectifications` only because
`PawsomeTracker` needed to import it from somewhere.

The refactor was behaviour-preserving by construction, and measured: the benchmark `SUITE` is
unchanged, which is what was expected — the conversions run per *call*, not per pixel, and the
composed maps the hot paths use are built once.

**Three things were considered and left alone. They will look like oversights; they are not.**

- **Wrapper types are not here.** `CONTEXT.md` says nothing in the type system catches a
  transposition, and a `DisplayXY`/`StoredRowCol` pair would change that. It is a *measurement*
  question, not a naming one: the same file records that an abstract `SMatrix` in `Hinvs` cost two
  orders of magnitude in `detect`'s background reduce, and the innermost parallel layer was removed
  after measurement rather than before. Extracting the conversions first is what makes the typed
  version cheap to try later — the call sites are now one function each.
- **The AprilTag index reversals stay inline.** `RegisteredWarp`, `canvas2raw`, `img_to_ground` and
  two more in `apriltag.jl` reverse `(row, col)` ↔ `(x, y)` by hand. They carry no `sar`, never
  cross a module seam, and sit in the stack's index pipe. Moving them buys a shorter file and
  spends the one thing that pipe is sensitive to. **`canvas2raw` is `RegisteredWarp`'s body written
  a second time seven lines below it** — a real duplicate, deliberately out of this change's scope
  rather than unnoticed.
- **`fix_window_size` was not converted.** Its `(w, h) → (rows, cols)` swap is fused with
  `oddify`, whose extra-pixel behaviour is documented as changing tracking on scaled or anamorphic
  runs and as needing a deliberate decision. Separating the swap from the rounding there is exactly
  the "side effect of a comment fix" that comment warns against.

Also not done: renaming the `aspect` column to `sar`. It is one quantity with two spellings
(`CONTEXT.md` now says so), but the csv name is user-facing and a rename has to travel into
`RENAMED_COLUMNS` and cannot be half-applied.

### The two frame-centre callers round differently, and that was preserved

`VerifyRuns.frame_center` and `Rectifications.default_center` compute the same display-space centre
and then disagree: the first is `(round(Int, x), height ÷ 2)`, the second
`SVector{2,Float64}(x, height / 2)`. On an odd height those differ by half a pixel, and the x by a
rounding.

Only the shared half — `display_center_x`, the part carrying the `sar` rule — was extracted. The
rounding stayed at each call site, which is what keeps the extraction behaviour-preserving and what
makes the difference visible instead of buried in two files.

**Measured, and it does not matter.** The deviation is at most a quarter pixel in x and half a
pixel in y, and only on odd dimensions: 640x481 at sar 1 gives seed `(320, 240)` against origin
`(320.0, 240.5)`; 641x481 at sar 1/2 gives `(160, 240)` against `(160.25, 240.5)`; every even frame
gives zero. Neither consumer cares. `frame_center` is a search *seed* against a window of at least
21 px, so half a pixel is about 2% of the search radius. `default_center` is the coordinate
*origin*, used only when the csv declares no centre, and displacing an arbitrary-by-convention
origin by half a pixel yields a different but equally valid origin — every relative quantity
(distances, speeds, path shape) is unchanged.

They also never meet: `main` hands `track` the csv value `c.source.center` (`main.jl`), never the
builder's defaulted one, so no code path compares or combines the two. Each rounds for its own
consumer, and that is the end of it — no fix, and no reason to unify them.

---

## Rectifications

### Rectification builders take keywords, and are chosen by type (#68)

`Rectification(c::Video)` used to unpack its struct into **fifteen positional arguments**, and the
extrinsics-only variant into eleven — two methods of one function, told apart by nothing but how
many arguments arrived. The receiving signatures were bare names in a fixed order:

```julia
Rectification(file, extrinsic, start, stop, temporal_step, yadif, blur, width, height,
              n_corners, checker_size, aspect, radial_parameters, center, north)
```

`width`/`height` are both `Int`; `start`/`stop`, both `Float64`; `center`/`north`, both the same
optional pair. Transposing any of those pairs compiles, runs, and returns a wrong map — the failure
mode is a subtly rotated or mirrored arena, not an error. The test suite showed the cost directly:
one call read `R.Rectification(vid, extrinsic_t, missing, missing, Wimg, Himg, …)` with nothing to
say which `missing` was `yadif` and which was `blur`.

The four builders are now keyword-only and named for what they build — `from_checkerboard`,
`from_extrinsic`, `from_matlab`, `from_uniform`, matching the files they already lived in — plus
`PawsomeTracker.ApriltagRectification`. (Two were introduced here as `from_video` and `from_scale`
and renamed by #189, along with their files, for the same reason they were named at all: the csv
vocabulary calls them a checkerboard and a uniform rectification. The old names appear nowhere in
the tree — `git log --grep '#189'`.) Arity no longer selects anything; the calibration's type
does, in `VerifyRectifications/types.jl`, which is the only module that can see both
`Rectifications` and `PawsomeTracker`. The seven facts every builder needs about the source video
travel together as `_source(c.source)`.

`Rectifications` declares `function Rectification end` and exports it, but every method lives in
`VerifyRectifications`: this module owns the concept and the builders, the gateway owns the types
the dispatch is on.

What the four builders *return* is `StaticRectification`, a struct, and was for a long time an
anonymous `(; image2real, real2image, ratio, width, height)` NamedTuple written out at three
separate return sites. One shape, three definition sites, kept in step by hand — the same argument
as #140/#141, and the same failure mode: a builder could drift a field name or drop one and nothing
would say so until a caller reached for it. The struct also gives the exported concept a name, so a
signature can finally say "a rectification"; `Rectification` was a function with no type behind it.

The name marks the real distinction, which is *not* the one the old duck-typing implied. The two
rectification shapes were never interchangeable: `ApriltagRectification` has **no `real2image`** at
all, and carries `reference` and `family` that the builders' shape lacks. They overlap on four
fields, not five. "Static" is what the builders' path actually is — the camera does not move, so a
single fixed map pair describes the whole run — against the AprilTag path, which re-registers every
frame against a shared reference and therefore has no one inverse map to offer.

`track` still selects between the two with `rectification isa ApriltagRectification` rather than by
dispatch, which reads against the rule two sections up. It is deliberate: the two paths share a
six-line preamble (`dia_fps`, the segment count, the pre-scaled `width`/`window`/`search`), so
dispatching means either duplicating that across two methods or threading eight locals into a
helper. Both are harder to read than the branch. The rule exists to serve clarity; here it would
cost it.

### A builder returns a rectification and writes nothing (#209)

The three builders that produce a `StaticRectification` — `from_checkerboard`/`from_extrinsic`
(through their shared `_rectification`), `from_matlab`, `from_uniform` — used to write the
diagnostic jpeg on the line immediately before their `return`. `build_rectifications` writes it now,
from the value the builder just handed back: `width`, `height`, `ratio` and `real2image` are all
fields of that value, so nothing extra has to be threaded down to reach the renderer.

What that bought is not the line count — the diff is roughly neutral — but the argument lists.
`rectification_diagnostics` is a caller instruction, a `Bool`, and it travelled five frames from
`main`'s signature to reach a file write buried inside three otherwise-pure functions. It stops at
`build_rectifications` now, so `Rectification(c)` takes no keyword at all and `test/quality.jl`'s
"every builder keyword is a rectifications.csv column" no longer needs it carved out of the allowed
set (#140/#141 got *tighter*, not looser). Three more arguments went with it: `file`, `extrinsic`
and `rectification_id` were the diagnostic's only consumers in `from_matlab`, `from_uniform` and
`_rectification`, so those three take neither the video nor the id that names the image. Neither
`from_uniform` nor `from_matlab` touches the source video any more — `from_uniform` reads nothing at
all, and `from_matlab` reads only its `.mat`. The cost had been landing on the tests, which
fabricated `file = "unused.mp4"`, `extrinsic = 0.0` and `rectification_diagnostics = false` at nine
call sites that wanted none of them.

`rectification_diagnostics` remains on `main` and `only_rectify` unchanged: it is user-facing and
documented in `docs/src/help.md`. Only the builder surface lost it.

**Considered and not done.** Rendering inside the five `Rectification(c)` dispatchers, one frame
lower, keeps them the single place that knows about each rectification kind — but it repeats the
same render line five times and leaves the flag as a dispatcher keyword, which is exactly the
journey this removes. Keeping `rectification_id` on the builders "for symmetry" was rejected for
the plainer reason that it would then be an argument no builder reads. And a
`save_diagnostic(::Any, args...) = nothing` fallback in `Rectifications` would have avoided the
second method entirely, at the price of silently doing nothing for any future rectification shape
that forgets to define one. So the AprilTag no-op is typed. It sits in `PawsomeTracker`, beside the
struct, and not in `Rectifications` beside the method it pairs with, because `Rectifications` is
included first and cannot name `ApriltagRectification` in a signature; `VerifyRectifications` can
see both modules and was the other candidate, but it owns neither the function nor the type, where
`PawsomeTracker` owns the type — the same ownership test `VerifyRuns` passes when it extends
`Parsing.mytryparse` on `MyWindow`.

### The camera model is a type, and the builders' shared tail is keyword-only

#68 made the four public rectification builders keyword-only, for a reason it stated plainly: their
arguments are same-typed neighbours, so a transposition produces a silently wrong map rather than an
error. It stopped at the public seam. One frame in, `_rectification` took 13 positional arguments
and `_maps` another 13, and `obj2img` took the same four intrinsics a third time.

Measured the same way as the tracking half, by transposing a pair at the `_maps` call site:

| transposition | suite |
|---|---|
| `width` / `height` | caught, 1 failure |
| `center` / `north` | caught, 1 failure |
| **`frow` / `fcol`** | **not caught, 535/535 passed** |
| `crow` / `ccol` | caught, 1 failure |

Three of the four were caught by exactly *one* assertion each, and the fourth by none.

**Why the focal lengths were invisible, which is the part worth remembering.** `fit_model` seeds
`cammat[2,2] = aspect` and fits under `CALIB_FIX_ASPECT_RATIO`, so at `aspect = 1.0` the fit returns
`frow == fcol` **bit-for-bit** — verified directly: 150945.0919 for both at aspect 1, against
201295.8/100647.9 at aspect 1/2. Every checkerboard fixture in the suite is square, so the swap was
a literal no-op. That is the same blind spot as #130 ("invisible at sar = 1, which is why it stood
as long as it did") and #197, for the third time.

`CameraModel` now holds the seven values `CONTEXT.md` already calls a camera model — intrinsics,
distortion and pose. It is **keyword-only, with an inner constructor replacing the positional
default**, so there is no positional form of it anywhere to transpose; `obj2img` and `_maps` take
the model, and `_rectification` is keyword-only. `R` and `t` are converted to `SVector{3, Float64}`,
which is the same arithmetic `obj2img` did inline (`RotationVec(R...)`, `SVector{3, Float64}(t)`).

The blind case is now pinned directly, at asymmetric and unequal focal lengths, in
`test/Rectifications/test_geometry.jl` — transposing them inside `obj2img` fails exactly that
testset and nothing else.

`_rectification` and `_maps` stay out of the #140/#141 builder-keyword invariant, with a comment in
`test/quality.jl`: their keywords include fitted and derived values that are not csv columns, so
adding them would fail the containment immediately.

### `main` processes, `verify` reports — a flag no longer picks the return type

`main` used to take `strict::Bool`, and so did `load_runs`/`load_rectifications` beneath it. It did
not merely change behaviour, it changed the **return type**, and not even consistently: under
`strict = false` a *dirty* file came back as the annotated `DataFrame` and a *clean* one as the
built vector. The return type therefore depended on the data, not just the flag, which is why
nobody could write a signature for it.

The cost was visible at every call site. `main.jl` carried `cs isa AbstractDataFrame && return cs`
followed by `cs::Vector{RectificationMethod}` — an `isa` test and a type assertion whose only job
was to stop the union leaking far enough for JET to complain about `length(::DataFrame)`. The test
suite had a matching assertion recording the asymmetry as intended behaviour.

Split in two, by what the caller actually wants:

- `main` / `load_dataset` / `load_runs` / `load_rectifications` — **build, or throw.** One return
  type. The first-tier identity gate still aborts before any video is opened, because the run is
  going to fail whatever the videos say (#121, #122).
- `verify` / `check_dataset` / `check_runs` / `check_rectifications` — **report, never throw.**
  Always the annotated DataFrame, *including when nothing was wrong*. That unconditional return is
  the point: it is what makes the type independent of the data. There is no first-tier abort here,
  since nothing is going to be built and the rest of the file is still worth validating.

Both share `_validate_dataset`, so the pipeline itself is written once and the two entry points
differ only in what they do about what it found.

`strict` is gone rather than deprecated. It was a keyword on a lab tool with a handful of users, and
leaving a forwarding shim would have preserved the one thing worth removing: a Bool that reads as
"be strict" but means "and also hand me back a different type". `verify` also takes no `run_ids` —
narrowing decides what gets built, never what gets checked, so validation was always over every row.

### The extrinsics-only rectification is selected by absence, and never flagged

Which constructor a rectification gets is decided *solely* by whether the rectifications.csv row has an
intrinsic window: both `start` and `stop` blank ⇒ the single-frame fit, where pose and focal
length come from the extrinsic frame alone with every lens-distortion coefficient fixed at zero.

A row that omits the window but still fills `temporal_step` / `radial_parameters` is deliberately
**not** flagged as inconsistent; those two are silently ignored. Leaving both window bounds out is
too large an action to happen by mistake, so it expresses intent, and stray leftover parameters
should not override that intent with an error. (A filled column belonging to a different `type`
*is* flagged — that is a different situation.) Filling only one of the two bounds is rejected
upstream.

### A single planar view needs its principal point fixed

One planar view leaves focal length + principal point + pose underdetermined by one degree of
freedom. `fit_model` therefore adds `CALIB_FIX_PRINCIPAL_POINT` when there is exactly one view,
pinning it at the image centre (OpenCV's default without an intrinsic guess), which makes the
single-frame fit well-posed.

### Lens distortion is inverted by bisection on the monotone branch

The forward radial map `g(r) = r·f(r)` is invertible only up to its first critical point — beyond
that the distortion "folds" and the inverse is ill-posed. `_first_critical` locates that fold as
the smallest positive root of `g'`, and the inverse is solved by bracketed bisection inside it. A
point beyond the fold (the peripheral "donut" region) has no physical preimage, so its radius is
clamped to the fold with a warning.

### Rooting the polynomial was measured and declined (#68)

The claim that used to stand here — that `inv_lens_distortion` "runs per pixel, inside the warp of
every diagnostic frame" — is **wrong**, and it is worth stating plainly because it is what made
this candidate look urgent. Every `warp` in the package composes `real2image`, which uses the
*forward* `distort`. The inverse is reached only through `image2real`, and that is applied once per
tracked coordinate (`map(rectification.image2real, ij)`), once per written diagnostic frame for the
marker, and a handful of times when a rectification is built. For a 30-minute run at 25 fps that is
45,000 calls, not 300,000 per frame.

The equation is a degree-7 polynomial and `Polynomials` is already a dependency, so the
companion-matrix version was written and measured against the bisection solver over the same sweep
of frame sizes, fields of view and distortion regimes:

| | bisection | polynomial root |
|---|---|---|
| worst residual over the sweep | 1.3e-11 px | **8.8e-13 px** |
| 640 inversions | **286 µs** | 3,573 µs |
| allocations | **3** | 21,763 |

The root solver is 15× more accurate and 12.5× slower. Both numbers are real, and the accuracy one
does not matter: 1.3e-11 pixels is ten orders of magnitude finer than the ~1 pixel RMSE of the
tracking it feeds, so the extra digits buy nothing a caller could observe. The cost does show up —
about 250 ms rather than 20 ms per long run, and 34 allocations per call inside `tmap`-parallel
tracking. Declined.

The fallback the candidate suggested does not survive either. Dropping the bracket-doubling branch
is unsafe: it runs when `rstar` is `Inf`, and `g(r) < r` there whenever a coefficient is negative,
so `rd` is not always an upper bound. Cutting the 200-iteration cap changes nothing — the
`b - a < 1e-14` exit fires after about 47 halvings, so the cap never binds.

What did come out of this is a test. `test_lens_distortion.jl` now sweeps observed pixels across
frames from 100×100 to 2000×2000 at two fields of view and five distortion regimes, requiring each
recovered point to map back onto the pixel it came from to within 1e-9 **pixels** — the unit the
accuracy has to be judged in, since the solver works in normalized coordinates and the error a
caller feels is scaled by the focal length. Any future replacement has to clear that bar.

### `n_corners` must be at least 3 in both dimensions

OpenCV's `findChessboardCorners` rejects anything smaller ("Both width and height of the pattern
should have bigger than 2"), so `(2, n)` used to pass validation and then throw out of the
detector. Checking the precondition in the gateway beats catching the failure in the detector.
It also subsumes a degenerate case of its own: `checker_width_pixel`'s `2·prod(n) − sum(n)` divisor
is zero at `(1, 1)`.

---

## Tracking

### `sample_fps` is a request, not a promise (#15, #17)

The sampler advances whole frames, so the deliverable rates are `native_fps / skip`. The sample
count and every timestamp are derived from that **effective** rate. Deriving them from the request
instead made a non-divisor `sample_fps` either overrun the video, or label the track with times its
frames were never taken at.

Relatedly, sample *i* is raw frame `(i-1)·skip`, i.e. `start + (i-1)/effective_fps`. Spreading the
samples evenly over `[start, stop]` instead pinned the last one to `stop`, stretching every
timestamp by up to a frame period even when the request divided the rate evenly (#17).

(Both were `fps` at the time; see the entry below for why that one name became two.)

### The video's own rate and the rate we sample it at are two parameters, not one

`fps` named both. They are equal by default, which is why one column carried them for so long, and
the moment they differ the single name has to mean one of them: the *request* in `runs.csv`, and
the *video's own rate* in every expression that consumes it (`frame_skip`, the sample count, the
timestamp step, the diagnostic's playback speed).

The video's rate therefore had two definition sites — the gateway's ffprobe read, kept on the
`Tuning` as `video_fps` and used only to declare the diagnostic's playback rate, and a second
`VideoIO.framerate` call inside the `Video` constructor that the actual sampling used. That is the
shape #140/#141 closed everywhere else, and it had the same consequence: a run was verified against
one number and sampled at another, and there was no way to state the rate at all, so a video whose
container misreports its own frame rate could not be tracked correctly by any combination of csv
cells.

The columns are now `native_fps` (what the video runs at — probed by default, declarable when the
file is wrong) and `sample_fps` (what to track it at, defaulting to `native_fps`), and `Video` takes
both rather than asking the container. Two consequences worth keeping:

- **The cascade is one-directional.** `sample_fps` falls back to whatever `native_fps` resolved to,
  never to the probe a second time — so declaring only `native_fps` moves both, which is what makes
  "this file is really 25 fps" a one-cell statement.
- **`native_fps` cannot exceed the probed rate.** `start`/`stop` stay in the file's own seconds, so
  a higher declared rate claims more frames in the window than the file holds and the sampler runs
  off the end mid-run. Verified in the gateway rather than left to fail as an EOF in the tracker:
  the gateway's promise is that `track` cannot error, and a settable rate is only safe while that
  promise holds. The declaration that matters — a file overstating its rate — is the other
  direction, and is unrestricted.

A rate declared on any row of a multi-segment run is spread across the run before the probe fills
the blanks. Segments are pieces of one recording, so the claim is about all of them; without the
spreading the blank rows would take their own files' probed rates and then read as *disagreeing*
with the row that declared one. Two rows declaring different rates are rejected, since both claims
describe the same recording. This is also what #95 chose not to enforce on the probed rate, for
fear of rejecting one recording whose containers spell the same rate differently — that exposure is
unchanged (the imputed rate has always reached the consistency check through the blank-cell path),
and declaring the rate is now the way out of such a rejection rather than a way into one.

### The run's clock counts frames, and closes up whatever lies between segments (#153)

A run's timestamps are one range: the first segment's `start`, the shared step, and the total
sample count (`_concat_timestamps`). Every later segment's own `start` is discarded. So a run whose
segments are two windows of one file, cut either side of an untrackable stretch, produces timestamps
that run straight through the stretch as if it had been tracked — measured, on a 2 s fixture cut at
0.0–0.8 and 1.2–2.0: `0.0:0.04:1.56`, 40 samples, the 0.4 s hole gone and every sample after the
seam labelled 0.4 s early.

That is deliberate, and the alternative was considered and declined. Preserving the real jump is
possible *within a file* — those times are comparable — so `_concat_timestamps` could offset each
same-file segment by its own `start` and produce an honest, non-uniform timeline. It was not taken:

- The lab cuts stretches out to remove what should not be tracked (animal out of view, a hand in
  the arena, unusable footage). The track is meant to read as one continuous crossing, and speeds
  derived from it are meant to ignore the removed time, not to average over it.
- The removed time is never lost: it is in `runs.csv`, and can be put back post-hoc by anyone who
  wants it.
- `ts` stays a `StepRangeLen`. Preserving the jump makes it a `Vector{Float64}`, which changes
  `track`'s return contract, the `track` column of `main`'s DataFrame, and the track writer, for a
  number the analysis is choosing to discard.

The other half of #153 — validating that segments are in order and do not overlap — is not covered
by this entry, and was done *within a file*: `verify_segment_windows!` requires each window's
`start` to be at or after the previous same-file window's `stop`. Across files it is impossible,
and was ruled out rather than deferred: each file's `start`/`stop` are in its own seconds, so
nothing in the data relates two files. Container `creation_time` would be the only lead, and
reading it was declined as too unreliable (frequently absent, frequently mangled by timezone) to
reject good footage over. The csv row order is the user's statement of what follows what, and the
user's to get right.

### The background stack stores `Gray{N0f8}`, and `detect` widens before subtracting (#27)

The stack is the largest allocation in the program: a 1080p frame at `background_length = 250` is
~494 MB as `N0f8` against ~1978 MB as `Float32`. The values came from an `N0f8` decode, so the
wider type buys no precision.

The subtraction, however, must be widened first. A darker target makes the difference negative,
and `N0f8` is unsigned and wraps silently rather than erroring
(`Gray{N0f8}(0.2) - Gray{N0f8}(0.5) == Gray{N0f8}(0.702)`), which would leave a background-matching
pixel at 0 and a pixel one quantum darker near 1.0 — the DoG chasing inverted noise. `Tracker.img`
is `Float32` precisely to hold the signed result.

### The target is kept out of its own background model

The stack doubles as the background model and as `detect`'s source of the current frame, so the
frame must enter whole (detect has to see the target) and the protection happens *after*
detection: once the position is known, the target's search window in that slice is restored to the
pre-target background the evicted frame held there. By induction the history never contains the
target.

Without it, a target that sits still for longer than the rolling window is absorbed by the
per-pixel max/min, erased from the subtracted image, and the tracker wanders off. (The prefill in
`collect_stack` is deliberately unprotected: absorption needs the stationary spell to exceed the
whole background window within the rolling phase.)

The reduction is `maximum` for a darker target and `minimum` for a lighter one: a darker target
never raises the per-pixel maximum over time, so `maximum` sees through it, whereas a lighter
target *is* the maximum wherever it ever passed and would erase itself, leaving a ghost swath
along its own trajectory.

### `background_length = 0` keeps a 2-slice stack

Zero turns background subtraction off, but the stack itself stays, because it is also `detect`'s
source of the current frame. It holds 2 slices rather than 1: a single-slice stack has no valid
linear-interpolation stencil along the slice axis.

### One `track` body, not four (#68)

`track` had two methods — one video and several — and each carried an AprilTag branch and an
ordinary branch. All four resolved `window_size` from `missing` the same way, computed `dia_fps`
the same way (comment included, twice, verbatim), opened and `finally`-closed the diagnostic, and
stitched the timestamps with the same two lines.

The vector method is now the implementation and the single-video method is a wrapper around a
one-element vector. That was checked to be equivalent before the change, not after: identical
timestamps (same values *and* the same `StepRangeLen{Float64, TwicePrecision…}` type), identical
coordinates and type, and a diagnostic video of the same dimensions, frame count and rate. Cost:
within noise on wall clock, +16 allocations out of ~1000. The AprilTag path keeps its exact
guarantee under test — `findall(ismissing, xy) == occluded` pins where a lost tag reports `missing`,
through the wrapper.

The keyword the wrapper still declares itself is `start_location`, because its type annotation is
load-bearing (see below).

### The tracking functions take typed objects, and the two paths take different ones

`track_one` took thirteen positional arguments and `track_apriltag` sixteen, each unpacking the
caller's `Segment` and `Tuning` and repacking them one frame down — the arrangement the comment on
`detect` already called out as "the one hot path that undid that", except it was not the only one.
Six of `track_one`'s thirteen were bare `Float64`s.

That was measured before it was changed. Transposing a pair at the call site, on unmodified `main`:

| transposition | suite |
|---|---|
| `native_fps` / `sample_fps` | caught, 15 failures |
| `start` / `stop` | caught, 3 failures + 24 errors |
| **`target_width` / `initial_search_factor`** | **not caught — 433/433 passed** |
| **`ref_sz` inverted to `(width, height)`** | **not caught — 433/433 passed** |

Both blind cases now have assertions, and the signatures are `(segment, tuning, scaled, dia)` and
`(segment, tuning, scaled, dia, rectification)`.

`ScaledTuning` holds the three `downscale`-scaled values `track` derives once per run. Its fields
are `width`/`window`/`search`, deliberately NOT the column names, because they hold scaled values
and a field called `target_width` that is not `target_width` is the same quiet lie as a `RowCol`
holding `(x, y)`. It is absent from the #140/#141 invariant for the same reason, with a comment in
`test/quality.jl` saying so: derived values are not tracking parameters.

**The asymmetry is the load-bearing part, and it will look like an oversight.** `track_one` takes a
`ResolvedSegment`, whose `start_location` union also admits `RowCol` — the carried-over form a later
segment's start takes when it chains from the previous segment's last coordinate, which a `Segment`
cannot hold (#18). `track_apriltag` takes a plain `Segment`, because AprilTag segments do **not**
chain, so no `RowCol` can ever reach it and `apriltag_guess` has no method for one.

Giving both the wider type was tried first, and JET rejected it: `no matching method found
apriltag_guess(::SVector{2, Float32}, …) (1/3 union split)`. That is bug #18's exact shape — a type
the signature advertises that the callee cannot handle — and the suite passed with it in place. So
which of the two types a tracking function takes now states whether its path chains, and the pair
must not be collapsed into one.

### What the tracker's argument lists still do not pin

The `ref_sz` assertion is on `reference_size` directly, not on a tracked path. A behavioural test
was attempted and does not discriminate: a transposed reference viewport of comparable size still
*contains* the disc, because the fixture's disc sits near the middle of the ground plane, so
tracking succeeds either way. Making it discriminate needs an aspect ratio extreme enough to push
the disc outside the transposed viewport while all four tag blocks stay in frame at every pose, and
the fixture's fixed tag layout (ground rows/cols 150..450 on a 600x600 canvas) cannot currently do
both. The non-square AprilTag test that exists is honest about covering the pipeline rather than the
axis order.

### What was deliberately *not* merged

The AprilTag and ordinary branches still stand apart, and the last line of each still differs:

```julia
isnothing(rectification) ? (ts, ij) : (ts, map(rectification.image2real, ij))   # ordinary
_apply_image2real(rectification.image2real, reduce(vcat, segs))                # AprilTag
```

`_apply_image2real` is missing-tolerant and would cover both — but only by widening the ordinary
path's return element type from `SVector{2, Float64}` to `Union{Missing, SVector{2, Float64}}`, for
every run that can never produce a `missing`. The two branches also track with different functions
(`track_apriltag` vs `track_one`), hold different element types, and differ on whether segments
chain their start locations. One `if` is the honest shape.

### `start_location`'s declared type is exactly what is supported (#18)

`CartesianIndex{2}` sat in the keyword's `Union` with no `get_guess` method behind it, so a call
type-checked and then died with a `MethodError` once the video was already open and the background
stack built. The union now names only what works. `RowCol` is absent on purpose despite having a
method: that is the internal form a *later* segment's start takes in the vector method, carried
over from the previous segment's last coordinate, not something a caller supplies.

### A run's segment count is data, not a type (#68)

`Run` used to be abstract over `SingleRun` (scalar `file`/`start`/`stop`/`start_location`) and
`MultiRun` (the same as aligned vectors). The split cost two `track` methods, two `get_duration`s,
a separate `impute_start_location`, and a constructor branching on `nrow(g) == 1`.

The comment above it said the segment count was "materialized in the *type*, so `track` dispatches
on it with no runtime branch". **That was wrong.** `load_runs` returns `Run[Run(g) for g in …]` — a
`Vector{Run}` whose element type was *abstract*, so every `track(r)` from `main` was a dynamic
dispatch anyway. Collapsing to one concrete struct is what actually delivers the static call:
`isconcretetype(Run)` is now true, and so is the vector's element type.

Routing a one-segment run through the vector `PawsomeTracker.track` was checked to be equivalent
before the change, not after: identical timestamps (same values *and* same
`StepRangeLen{Float64, TwicePrecision…}` type), identical coordinates and type, and a diagnostic
video of the same dimensions, frame count and rate. The encoded bytes differ, but a control of two
identical *scalar* runs differs too — H.264 here is not byte-reproducible, so that comparison
proves nothing either way. Cost: within noise on wall clock, +16 allocations out of ~1000,
identical peak memory.

What it gives up: a single run's video is `only(r.files)` rather than `r.file`, and the type no
longer states "exactly one segment". Two call sites in `src/`, so the price is small — but it is a
price, and `verify_run_consistency!` is now the only thing asserting the shape.

### `Tuning` keeps its name; the seam is scope, not facts-versus-knobs

The name looks wrong on inspection, and will keep looking wrong: `native_fps` is probed,
`darker_target` is a property of the footage and `target_width` is a measurement of the animal —
three of eight fields are observations, not knobs. Splitting them off into a second struct, and
renaming to `TrackingParameters`, were both considered and declined.

The split is a solution to the wrong seam. What actually separates `Tuning` from `Segment` is
*scope* — what one run shares versus what varies within it — which is the rule
`verify_run_consistency!` already enforces and the reason both types exist. A facts/knobs split
cuts across that at right angles, costs an argument at every call site, and buys nothing at the one
site that consumes it. The rename churns an exported name to fix a definition.

So the definition moved instead of the code: membership is *run-level, and an argument of `track`*
(see CONTEXT.md). That rule also explains the field that is run-level and still not on `Tuning` —
`frame_format`, which the gateway consumes to place a start location and `track` never sees.

### A run's imputed start location must not mutate the run (#23)

Assigning the resolved first-segment location back into `r.start_locations` meant the first
`track` call wrote its `center` into the run, so a later call with a *different* `center` silently
kept the first one — and the frame-centre fallback became unreachable too. A `Run` describes what
the CSV said; tracking it leaves it alone.

This used to be structurally impossible for a one-segment run, whose `start_location` was an
immutable scalar field. Since the segment-count collapse it is a one-element vector taking the same
imputation path, so the guarantee is asserted for one-segment and many-segment runs alike.

### Anamorphic video

The stored frame is squeezed horizontally by the sample aspect ratio (`stored x = display x / sar`).
Window sizes arrive in display pixels and their column extent is converted to stored pixels,
otherwise an anamorphic (sar < 1) target fills its own search window. `start_location` is likewise
a display-pixel convention and is bounds-checked against the display width, `width × sar`.

A rectification's `center`/`north` were described here as *not* being handled the same way, and for
a while they were not: bounds-checked against the *stored* width with no `sar` applied, and scaled
by `aspect` in `fix_coordinate` where the tracker's `get_guess` divides by it — the two halves of
the pipeline disagreeing about which direction `sar` goes for the same user-supplied value. #130
fixed both. `fix_coordinate` now divides, and the bounds check multiplies the stored width by the
aspect to get the display width to check against. The two halves agree, and
`test/Rectifications/test_geometry.jl` and `test/Rectifications/test_from_uniform.jl` pin the
direction with asymmetric values.

All of it was invisible at `sar = 1`, which is why it stood as long as it did — and that is the
lasting point of this entry rather than the specific bug. #36 closed as "aspect ratio works across
the whole system", but every fixture that exercises tracking is square in display space, so a
transposed axis is not what those tests measure.

### One diagnostic writer, three scenes (#68)

`Diagnose`, `DiagnoseRectified` and `DiagnoseApriltag` were three structs carrying the same fields
and repeating the same body: bump the counter, skip unless this is the `skip`-th frame, place the
marker, push the trace, draw the circle and the path, stamp the label, write.

Only two things ever differed — how the raw frame becomes a canvas, and where the tracked point
lands on that canvas — so those two are now a *scene*: a callable
`(frame, point, extra...) -> (canvas, ij)` plus a `canvas_prototype` that gives the writer its frame
size. Everything else lives once, in `Diagnostic`. A fourth diagnostic mode is a scene, not a struct.

The marker radius and label size stay per-mode (they scale with the canvas), and the circle's
thickness is `max(1, radius ÷ 2)`, which reproduces all three of the old hardcoded values exactly.
`ij` may come back `missing` — the AprilTag scene cannot locate the target on a frame without a full
tag set — in which case the frame is still written, just unmarked, as before.

One rendering detail changed. The unrectified writer used to stamp the label *before* drawing the
marker, so a target that happened to sit under the text was drawn on top of it; the other two
stamped the label last. All three now stamp last, which is the order that keeps the label legible —
and the label exists precisely to be read (#22). The two orders only differ where marker and text
overlap, in the top-left corner of the frame.

### The AprilTag diagnostic carries a label too (#22)

`main` concatenates every run's diagnostic into one video, so without a label no segment can be
told from the next — and a dataset of drone runs is *all* AprilTag, so previously none of them
carried a label at all.

---

## AprilTag rectification

### Geometry decisions, verified against a real drone frame (1080×1920, four tag36h11 tags)

* A homography from all 16 tag corners registers frames robustly. A single tag's homography leaves
  3.5–13.4 cm of skew on distant tags (error grows with distance from the tag), so every fit uses
  every corner.
* The metric map is fit from all four tags jointly, each contributing its known square. Consensus
  drives the worst square error below 1 cm, against 13 cm for a single tag.
* The hand-written normalized-DLT homography is both more accurate (Float64 throughout, against
  OpenCV's Float32 marshalling) and faster (~28 µs against ~41 µs) than `OpenCV.findHomography`,
  so no OpenCV dependency is needed for it.

### The metric fit tries every tag as its bootstrap

The gauge-pinned iteration has convergence basins, and which bootstrap tag lands in the good one
is sensitive to sub-pixel corner noise — a 0.1 px difference flipped a real frame from 0.5 cm to
35 cm of error. So every tag is tried and the globally best result kept. On real footage at least
one bootstrap reaches sub-centimetre. It is a one-time few-millisecond cost per reference frame,
not a per-frame one.

The gauge pin itself (rigidly mapping tag 1's square back onto the canonical square each iteration)
is essential: without it the iteration's cm frame drifts in scale and pose, and diverges under
strong perspective.

### Registration happens in the stack's index pipe, not per guess

Every background-stack slice is lazily warped through that slice's own registration, so the DoG
tracker works in the shared reference frame — a static scene — with a stable background model and
no per-frame guess compensation. The cost is one homography apply per lookup.

Frames missing any tag yield `missing` (their true registration is unknown) and borrow the nearest
known registration for the background model, which misaligns them only by that brief unknown drone
motion. The previous native-space stack was misaligned by *all* drone motion.

`RegisteredWarp.Hinvs` is typed `SMatrix{3, 3, Float64, 9}` with its length parameter spelled out:
the abstract `SMatrix{3, 3, Float64}` boxes every per-lookup load and costs two orders of magnitude
in `detect`'s background reduce.

### Tags are found by expanding local search

Detection cost scales with pixels, so after the reference frame each tag is searched in a small box
around where it was last seen. Detecting on a crop reproduces the full-frame corners to better than
0.1 px (verified), so this is a pure speedup; the box grows and re-searches until the tag is found
or spans the whole frame, which degrades gracefully to full-frame detection when the drone jumps.

Detection is sequential rather than one task per tag, because `APRILTAG_LOCK` serializes every
detect anyway — parallel tasks would only contend on it.

The first frame of a run uses a full-frame scan, not an ROI around the reference positions: a run's
`start` can be far from the calibration's extrinsic frame, so the (stationary) tags may sit
anywhere in it.

### The AprilTag diagnostic is gauged by center/north, not by the tag fit

`ApriltagScene` used to build its canvas straight from `ref.M`, the raw metric map. That looked
harmless — the canvas has to be *some* frame, and the tags' cm bounding box is a natural one — but
it made the rendered world depend on something the user never chose.

`fit_metric` pins its gauge by rigidly mapping the lowest-numbered tag's square onto the canonical
square, so the whole cm frame is bolted to **that one board's body**. Two drone calibrations of the
same arena, two field days: the boards sat in the same four physical spots (positions agreed to
~7 cm once expressed in a common frame), but the board carrying id 0 had been turned 90° in place
and the other three ids had been shuffled between the remaining spots. The metric fit was perfect
both times — the centre-to-north distance came out 546.0 cm and 549.9 cm — yet the two diagnostic
segments rendered the terrain 89.6° apart, and read as mirrored. No `center`/`north` could fix it,
because the scene never saw them: `track` passed `rectification.reference` and the gauge lived in
the sibling field `rectification.image2real`.

The scene now takes the whole rectification and lays its canvas out in gauged real coordinates.
`center`/`north` name physical points, so two calibrations that agree about them agree about the
canvas — which is what `RectifiedScene` had always done on the video path. The framing still
follows the tags' bounding box, so the diagnostic keeps its resolution and its job of showing
whether the tags stand still.

This changes rendering **only for calibrations that supply `north`**. With `north` missing the
rotation is the identity and the gauge's translation is absorbed by centring on the bounding box,
so the canvas is unchanged pixel for pixel — asserted directly against the old formula in
`test/apriltag.jl`.

Making it work meant `apriltag_image2real` returning `northing ∘ centering ∘ XY_SWAP` instead of a
closure wrapping the same composition. The scene has to run the gauge *backwards* to sample the
source frame, and a closure cannot be inverted. `∘` collapses the three into one concrete
`AffineMap` whether or not `north` was given, so this also removed the small type instability the
old two-branch closure carried.

### Segments do not chain their start locations

Each AprilTag segment relocates on its own from its own `start_location`, and a missing one falls
back to the frame-centre search. Now that tracking happens in shared reference space, chaining a
segment's metric end position into the next segment's guess via `inv(ref.M)` would be possible —
it is deliberately not done yet.

For the same reason an AprilTag run ignores the calibration's `center` as a start fallback: that is
a pixel in the (moved) extrinsic frame, not in the run frame.

---

## The gateways

### The two gateways share their plumbing, not their rules (#68)

`VerifyRectifications` and `VerifyRuns` are the same pipeline over different columns: read and
screen the CSV, back-fill the columns a row type does not use, resolve paths against the data
folder, read each physical file once, null a field when a check trips, print what was wrong. That
sequence had been written out twice, close enough that a fix to one copy was routinely not applied
to the other.

It now lives once, in `src/gateway.jl` (`read_rows`, `backfill!`, `verify!`, `resolve_paths!`,
`read_per_file!`, `report_issues`), and the parsing of ffprobe's output moved alongside it into
`src/probing.jl` (`frame_geometry`, `parse_framerate`, `parse_sar`, `parse_sample_aspect`,
`is_interlaced`). `Gateway` knows nothing about either domain: every message it emits is either
passed in by the caller or built from a column name, which is what keeps `"file does not exist"`
and `"matlab_file does not exist"` — or `"(run_id: …)"` and `"(calibration_id: …)"` — one line of
code instead of two.

What deliberately stayed duplicated is what actually differs: each gateway's `COLUMNS`, its
`DEFAULTS`, its row parsers, its `probe_video` (they ask ffprobe for different entries and derive
different things from them), and its list of `verify!` calls — that list is the domain, and its
ordering is load-bearing (see below).

One behaviour was unified rather than preserved: `VerifyRectifications.parse_sample_aspect` used to
return a negative `Float64` for a negative numerator, where `VerifyRuns.parse_sar` returned the
square-pixel fallback. Both now take the fallback. No caller could use a negative aspect ratio, and
every case either suite pins was already agreed on by both.

### The frame dump stays out of `detect_per_group!` (#210)

The three `VerifyRectifications` detector passes — `verify_extrinsics!`, `verify_intrinsics!`,
`verify_apriltag_extrinsics!` — had written one skeleton out three times. It has one definition site
now, `Gateway.detect_per_group!`, whose own comment says what it does.

The reason it took a ticket rather than an afternoon is that the three passes vary on *three* axes,
not the two an obvious reading finds. Each has its own detector call and its own `blank!` column
list, yes — but two of them also dump the frame the detector saw into the issues folder and point
the message at it, and `verify_intrinsics!` does not, because it scans a whole window and so has no
single frame to dump.

Three shapes for that third axis were rejected:

* **A keyword on `detect_per_group!`** (`annotate = (k, issue) -> issue`, defaulting to identity).
  It would have put a third, optional callback channel on a function that already takes two, for the
  benefit of two call sites out of three — the open-channel shape #140/#141 exist to keep out.
* **Teaching `Gateway` to dump the frame.** It cannot: which column names a frame, that `:extrinsic`
  is the field to null, and how to read the frame at all are `VerifyRectifications` knowledge, and
  `Gateway` deliberately knows nothing about either domain.
* **Leaving the tail written out in both adapters.** The cheapest option, and the one that undoes
  the ticket: three lines duplicated between the two frame-dumping passes is exactly the shape the
  extraction was for, one level smaller. It is also where the live-view hazard below would sit
  twice, and be got right twice or wrong once.

What it is instead: `detect_per_group!` takes `detect(key)` and `flag!(group, key, issue)`, mirroring
`read_per_file!`'s `read`/`apply!` pair exactly, and handles only the one case that is not
domain-specific — a `nothing` from `detect` means the group passed, so `flag!` only ever sees a real
failure. The shared tail then sits in `VerifyRectifications.flag_extrinsic!`, a five-line helper the
two extrinsic passes call from their `flag!`; the intrinsic pass calls `flag_intrinsic!` instead,
which exists only so that all three call sites read alike. Two seams, each at the level that owns
what it knows, rather than one seam with a hole cut in it.

One hazard the extraction surfaced and the tests now pin: a group key is a **live view** onto the
parent's columns, not a snapshot, so a field a `flag!` nulls reads back through the key as `missing`.
Both frame-dumping passes build their whole message before calling `blank!`, and must keep doing so.

Allocations, from `SUITE["micro"]["gateways"]`: `check_rectifications` 8339 on `main` → 8350 on the
branch, stable across two branch runs. Read that as flat, not as +11 — the control says so.
`check_runs` measured 54144, 54142 and 54272 across the same three processes, and **VerifyRuns does
not use this seam at all**, so ±130 allocations is this benchmark's run-to-run noise on identical
code, and 11 is inside it. Worth knowing before anyone reads a small delta here as signal.

The larger caveat on that measurement: every row in the gateway benchmark is a `uniform`
rectification with a non-existent file, so all five are flagged before the detector passes run and
all three passes see **zero groups**. The benchmark measures the DataFrames plumbing around the
seam, not a detect through it. Measuring the loop itself would need real videos, which puts it in
the "macro" tier and at the mercy of this machine's wall clock.

The line count is worth recording because the ticket predicted the opposite: it expected ~40 lines
out of `verifications.jl`, and the change is net **+17 code lines** across both files
(`verifications.jl` 276 → 280, `gateway.jl` 105 → 118). The skeleton itself did concentrate — three
copies of ~6 lines became one of 8 — but each call site paid that back as an explicit argument list,
because the two column lists, the description and the two callbacks all have to be named somewhere,
and review then added a guard, a second named helper and three restored return values on top. So the
deletion test, read as line count, fails here; read as definition sites, it passes, and that is the
one that was worth having. Do not go looking for the missing 40 lines by folding the arguments back
into a keyword bundle.

### Plain DataFrames, not DataFramesMeta macros (#68)

Both gateways ran their columns through `@transform!`, `@chain`, `@groupby` and `@rtransform!` —
26 macro invocations, and two dependencies (`DataFramesMeta`, `Chain`) to supply them. Nearly all
of it was column assignment wearing a macro: `@transform! df :duration = missing` is
`df.duration .= missing`.

Three forms were on the table. Measured on a 200-row frame:

| form | median | allocations |
|---|---|---|
| `@transform!(d, :out = f.(:a))` | 16.0 µs | 90 |
| `transform!(d, :a => ByRow(f) => :out)` | 13.1 µs | 73 |
| `d.out .= f.(d.a)` | **3.2 µs** | **12** |

and for the dominant shape here, constant assignment, `@transform!(d, :out = missing)` is 15.5 µs
against 1.0 µs for `d.out .= missing`.

The rule this settled on: **broadcast for assigning a column, DataFrames' own functions for
operating on a table.** `subset`, `groupby`, `dropmissing`, `select!` and the `:col => ByRow(pred)`
predicate stayed exactly as they were — that minilanguage is doing real work in `verify!`, where
`skipmissing` and a view are the point. What it was not doing is earning a DSL layer for
`df.x .= y`. `@chain` blocks became sequential named locals, which also gave each intermediate
a name (`videos`, `clean`, `usable`) instead of a position in a pipeline.

Two traps the broadcast form has, both now in the code with comments:

- **`Ref` around a tuple.** `g.dimension .= (m.width, m.height)` broadcasts *elementwise* — one
  element per row. `g.dimension .= Ref((m.width, m.height))` is the macro's behaviour, verified
  column-for-column against it.
- **`[!, col]` and not `[:, col]`.** Nulling a field on a view has to widen the parent column to
  hold `missing`; `[:, col]` assigns in place and throws `MethodError: Cannot convert Missing`.

One redundancy fell out: `@transform! g :issues = push!.(:issues, msg)` assigned the result of
`push!` back into the column it had just mutated. `push!.(g.issues, msg)` says the same thing —
the vectors belong to the parent either way.

### What the change actually bought

Measured against `main` at the same DataFrames version (1.8.2), with the same benchmark file:

| | main | after | |
|---|---|---|---|
| `load_rectifications`, allocations | 12,272 | 7,251 | **−41%** |
| `load_runs` (200 rows), allocations | 40,644 | 37,147 | −8.6% |
| `load_rectifications`, wall clock | 17.8 ms | 16.9 ms | −5.4% |
| `load_runs` (200 rows), wall clock | 51.1 ms | 49.1 ms | −3.8% |
| `using Fromage` | 11.3 s | 11.5 s | no change |
| Fromage precompile | 3.9 s | 3.9 s | no change |
| Manifest packages | 294 | 289 | −5 |

**Read the percentages, not the counts.** Those absolutes were taken at `effcc68` (#79), through
`load_*(...; strict = false)` — the entry point #185 split into `load_*`/`check_*` — over a fixture
whose csv schema has changed since (`calibration_id`/`calibs.csv` then, `rectification_id`/
`rectifications.csv` now). Re-measured on one machine in 2026-09, the counts do not reproduce and
the drift is not recent: `69bf292^`, the commit just before #185, already allocates **54,948**
(runs) and **8,372** (rectifications). The gap therefore opened between #79 and #185, not in the
recent gateway work — the two fixtures differ only by those column renames, so the workloads are
the same shape, and #201–#204 and #209 land at 54,145 and 8,339. This is why an allocation count is
only ever a **within-session delta**: it is reproducible across processes and thread counts, not
across a year of dependency and fixture churn.

The allocation drop is concentrated in the rectification gateway because that is where the macros
were densest. **The TTFX improvement the candidate was partly filed on did not materialise**: load
time and precompile time are unchanged, and first-call latency moves 2–3%, consistently but
marginally. The precompile workloads still earn their keep — they warm the DataFrames column-typing
that remains — but the comment claiming `DataFramesMeta`/`Chain` macro machinery was the bulk of
first-call latency was wrong, and has been corrected.

### The issue report is a value; printing it is a separate half

`report_issues` built the report, printed it, and threw under `strict`, all in one function whose
only output channel was `println`. So every assertion about the report's *format* — which rows
appear, when the id is named, that `join` adds no trailing separator — had to run a gateway,
redirect stdout through a temp file (`Harness.capturing`, which needs a real file descriptor, not an
`IOBuffer`) and match a substring of what came back.

Split in two: `Gateway.issue_report(df, idcol, csv_name; mention)` builds the string or returns
`nothing`, and `report_issues(report, what, strict)` prints and throws. Each gateway owns a one-line
`runs_report` / `rectifications_report` so its id column and `mention` rule stay in one place. Output
is byte-identical — `println(a, b)` and `println(string(a, b))` produce the same bytes.

**An `IO` parameter was considered and rejected.** Threading one would have to reach `check_*` for
the gateway suites and, for the end-to-end tests, all the way to a new public keyword on
`main`/`verify` — user-facing API surface added for a test's benefit, when Julia already has
`redirect_stdout` for the genuine "what did it print" case. Making the report a value is the smaller
change and gives the tests the thing they actually wanted to inspect.

**`Harness.capturing` deliberately survives.** Four assertions still capture stdout, and should:
`test/fromage.jl`'s two end-to-end testsets check that `main` *tells the user* about an unmatched
`rectification_id`, and each gateway's tier-1 abort test (#121) checks what was printed before the
throw — in particular that the corrupt video's issue is ABSENT, which is the evidence that no video
was read. Those are assertions about printed behaviour, not workarounds for an untestable one.
What went away is `load_capturing`, in both suites.

**The `Issue` type was not done.** Failures are still `String`s in a `Vector{String}` column, so a
reworded message still breaks a test, and there is still no column attribution. That is ~25 `push!`
sites and ~98 messages, and it changes the `:issues` column `verify` hands back to users — a bigger
change with a narrower benefit than it looks, because `Harness.flagged` already asserts on
`df.issues` by value. Worth doing only if the message-text coupling turns out to hurt.

### Failures are reported, not thrown

A calibration whose extrinsic frame yields no corners, a `.mat` missing a required field, an
unreadable video — these are facts about the files the user gave us, not exceptional conditions.
They accumulate as issue strings on the row and are reported together, so one run of the gateway
tells the user everything that is wrong with their CSV.

`reference_frame` returns a `String` rather than throwing for exactly this reason; the two callers
that have nowhere to put a message (`ApriltagRectification`, and direct `ReferenceFrame`
construction) turn it back into a throw themselves.

### Issue messages are written as `<column> must …` (#226)

The messages the two gateways report are the package's primary interface for a bad csv — a lab
member with a rejected `runs.csv` reads nothing else — and they had drifted into four grammatical
forms, with `cannot` spelled two ways. They follow one form now, with stated exceptions:

1. A rule about a cell's value reads `<column> must <requirement>`, naming the column exactly as the
   csv header spells it.
2. A prohibition reads `must not` — never `cannot`, never `can not`.
3. A derived quantity names its inputs and still states the rule: `scaled target width (target_width
   × downscale) must be at least one pixel`, not `… is smaller than one pixel`.
4. Where the problem is an EVENT rather than a violated rule — detection found nothing, a file could
   not be read, a run's segments contradict each other — the message stays a statement of fact, but
   names the column or the file it is about. `no corners detected` is not improved by being forced
   into "must", so the convention is a rule with an exception rather than a blanket rewrite.

The reader is deciding what to type instead, which is why the rule beats the symptom:
`start_location is outside the frame` did not say the frame is measured in *display* pixels, and
`temporal_step too short` did not say what "too short" was.

Two classes are exempt. The parse failures — `wrong <column> format`, `wrong type`, `<column> is
missing`, and `read_rows`' `unrecognized column/s in <what> file` — are already column-first, say the
one thing there is to say about a cell that could not be interpreted at all, and are quoted
throughout the docs. So is `<column> is not used by type <type>`: it names both the column and the
type, and phrasing it as a rule about the column would point at the wrong cell, since what is
usually wrong is the `type`.

No behaviour changed — the same rows are rejected for the same reasons — but the text moved, so an
old issue report no longer matches the new one word for word.

### A failed check nulls its own field

`verify!` sets the offending field to `missing` after recording the issue, which makes every later
check skip that row rather than pile on. It is what keeps an inverted intrinsic window from also
reporting "temporal_step must yield at least 3 images", and a bad `path` from also reporting
"file does not exist". The ordering of the checks in `verifications!` is therefore load-bearing.

### Every read happens once per physical file

`:file` and `:matlab_file` are collapsed to canonical absolute paths (`joinpath` then `realpath`,
so `./x`, `a/../x` and symlinks all collapse to one key) before any reading. Grouping on that key
means one ffprobe per video and one `matread` per `.mat`, no matter how many rows or spellings
reference them. The same canonical path is the identity used for duplicate detection.

### Duplicate detection compares only clean rows

A row that already failed a check has had its offending field nulled to `missing`, which can make
two genuinely distinct rows be spuriously flagged as repeats of one another. Such rows are already
reported, so nothing is lost by excluding them.

What counts as a duplicate is type-dependent: `matlab` and `only_scale` rows must match on every
field; `video` rows match on an identity key (file, window, extrinsic, centre, north), since one
video can legitimately carry several rectifications differing in, say, `blur` — but two rows with
the same identity that disagree on the remaining parameters also get a conflicting-parameters
issue.

Within a duplicate set the **first row in csv order stands** and every later one is rejected: its
`:rectification_id` is nulled, so nothing downstream can join a run onto a rectification that was
thrown out.

### Duplicates are found by grouping, not by a shadow index column (#68)

The check used to copy the frame, append a throwaway `:_row` column carrying each row's index,
build three boolean masks, split video from non-video, and write the flags back through that index.
The bookkeeping was the part most likely to be wrong in a way no test would catch.

`parentindices` does the same job for free: the per-type frames are views of `df` all the way down,
so a group's rows already know where they came from. Both halves are now one `groupby` — the
non-video half over every column that is not `:rectification_id` or `:issues` (`:type` among them, so
the two kinds never group together), the video half over its identity key — sharing one
`reject_duplicates!`.

Equivalence was not taken on faith. Three semantics the old code encoded implicitly and nothing
asserted — that the duplicate's `:rectification_id` is nulled, that with three identical rows the
first is kept and *both* others flagged, and that the video and non-video halves are judged
separately — were written as tests against the old implementation first. Then both implementations
were run over 4,000 randomly generated frames drawn from a deliberately tiny value space (so
collisions and `missing`s are common, and a third of rows arrive pre-flagged): identical
`:rectification_id` and identical `:issues` every time.

### `comment` is exempt from the irrelevant-column check (#16)

A filled cell in a column the row's `type` never reads is flagged, because it usually means the
`type` is wrong. `comment` is consumed by no parser by design — it is free text and the docs
promise it is ignored — which made it look exactly like a wrong-type column and turned a filled
comment into a hard error under the default strict mode. It is the only column no type reads, so
exempting it closes the case completely.

### `run_id` is all-or-nothing

Either every row names its run (enabling multi-segment runs) or no row does, in which case each row
becomes its own single-segment run identified by its row number. A mixed file is rejected: under
partial numbering a blank row's auto-generated id could silently merge with an explicit one (say,
"3") into a bogus multi-segment run, so there is no safe way to honour it.

### `white_point` was removed rather than implemented (#19)

It was accepted, validated and plumbed through the gateway, and then never read by the tracker.
A CSV that still carries it is now rejected by name as an unrecognized column; since the value
never reached the tracker, deleting it changes nothing about tracking.

### The `scale` lower bound is a real limit, not a style rule (#24)

`scale` is a downsampling factor and the tracker works in the scaled frame, so it is the *scaled*
target width that must span at least a pixel — each factor can be individually fine while the
product is degenerate. Measured on a clean synthetic disc, accuracy decays smoothly as the scaled
target shrinks (~0.3% of `target_width` at scale 1, 0.7% at 0.25, 4% at 0.1), and below a scaled
width of roughly half a pixel the tracker stops finding the target at all, reporting positions
hundreds of pixels away — without throwing. The check uses the *declared* `target_width`, so
over-declaring it permits a scale too small for the real target; one more reason `target_width` is
worth measuring.

### "path must be the folder holding the video, not a file" (#33)

Putting the video itself in `path` is the common slip, and `isdir` alone reported it as "path does
not exist" — false, and it sends the user looking for a file that is plainly there. The targeted
check runs first and nulls `:path`, so the existence check does not also fire.

### The issues folder is only ever added to (#86)

`verifications!` used to open by recursively force-deleting `issues_dir` — a path the caller hands
in, defaulting to a relative `results_dir/issues` resolved against whatever the process cwd happened
to be. Naming the folder one level up (`results_dir` instead of `results_dir/issues`) wiped every
track and diagnostic; anything the user kept beside the dumped frames went with it; and because the
wipe ran first thing, a run that failed on the next line had already destroyed the previous run's
evidence. The precompile workload calls `load_rectifications` with that default, so precompiling the
package ran the `rm` too.

Freshness comes from newness instead of deletion. Each run dumps into a folder named for the second
it started (`issues/2026-08-20T14-22-05/`, counted apart when that second already has one), so a
folder holds exactly what its run wrote and nothing has to be removed to keep it that way.
`save_issue_frame` mkpaths on demand, so a run with nothing to report writes nothing at all —
including during precompilation. The stamp carries no colons, so the folders are creatable on
Windows.

Fromage removes nothing from the issues folder, including anything of the user's that happens to
live there. Cleaning it out is their call.

---

## Error handling

### No bare `catch` (#34, #25)

Every `catch` in the package names the exceptions it can actually handle and rethrows the rest.
Two things drove this: a bare `catch` around a retry loop ate `Ctrl-C` for the whole backoff
sequence, and a bare `catch` around a parse relabelled genuine bugs (`MethodError`, `BoundsError`)
as user-facing "bad file" messages.

Where the narrowing looks suspiciously broad, it is because the library underneath signals
everything the same way — `MAT.jl` reports essentially every corruption through a generic
`error(...)`, and OpenCV reports every C++ error as a plain `ErrorException`. `ErrorException` is
then as narrow as it can honestly get, and it still excludes the `MethodError`/`BoundsError` of a
bug on our side and the `InterruptException` a bare catch would swallow.

Where a check can replace a catch, it does: `matlab_dimension` and `matlab_extrinsic_count`
validate the shape and element type of the `Any` they read instead of catching the `InexactError`
that a malformed value would eventually cause.

**Cleanup inverts the rule (#160, #149).** A `catch` whose job is to stop cleanup from *becoming* the
failure the caller sees catches everything and warns, rethrowing only `InterruptException` — the
opposite shape to every other catch here, and deliberate. `PawsomeTracker.warn_on_failure` is the one
that names it, and every close of a native resource in that module goes through it: the diagnostic
writer of a failed export (#160), and the video reader, whether its `Video` construction failed, its
tracking run threw, or it was the one-shot extrinsic read (#149). All of them close from inside a
`finally`, where anything raised silently replaces the exception already on its way out. That
exception is the one explaining what went wrong, so nothing from cleanup may reach the caller.
Narrowing is not available anyway — ffmpeg surfaces through VideoIO as a plain `ErrorException`,
and an unlink on the share reports what the share reports. Nothing is lost: the cleanup failure
goes to the log with its backtrace. The cost is the one #34 and #25 were about — a `MethodError`
from a bug in the cleanup itself is demoted to a warning too — and it is accepted here because the
alternative is losing the failure the user actually needs to see. The same shape, for the same
reason, is already in `save_issue_frame` and both precompile workloads.

### Process failures print what happened, not the `Cmd` (#67)

`showerror` on a `ProcessFailedException` prints the whole failed `Cmd`, including the env-baked
`PATH` and `LD_LIBRARY_PATH` — some 7–8 kB — and that message goes straight into the user-facing
issues report. The exit status carries nothing a user can act on either. So ffmpeg and ffprobe
failures get a sentence saying the file is corrupt, truncated, or not a video, and everything else
still prints in full.

`_failure_message` is deliberately one method with a branch rather than a pair of methods
dispatching on the exception type: a method whose whole body is a string literal is const-folded
away, so its instrumentation never runs and coverage reports the line as missed even though the
tests exercise it.

### A successful ffprobe that describes no video is still "unreadable"

Reaching the field parsing means ffprobe *succeeded* and still could not describe a video: it
opened the file but `-select_streams v:0` matched nothing (an audio-only file), or it recognised
some container in what is really junk. Both mean the same thing to the user, so they join the
"issue reading from video file" family rather than getting a message of their own — which would
suggest our parsing broke rather than their file being bad.

---

## CSV cell parsing

### `mytryparse`, not `Base.tryparse`

Defining our own avoids type piracy on `Base.tryparse` for types we do not own (`String`,
`NTuple`). The generic fallback delegates to `Base` for the standard types.

### Cells are trimmed, and a blank cell is an absent cell

A stray space must not turn `" file.mp4"` into a missing file, or `"id "` versus `"id"` into a
missed duplicate. A present-but-blank cell is treated exactly like an absent one, so a required
field reports "is missing" rather than silently becoming an empty string, and an optional field
falls back to its default.

**Where the trimming actually happens matters, and `MyTemporal` had to be fixed for it.** The rule
above was implemented by trimming in the `String` parser and otherwise relying on Base, whose
numeric parsers skip surrounding whitespace on their own. `Time` is the exception: `tryparse(Time,
" 00:01:30 ")` is `nothing` where `tryparse(Float64, " 12.5 ")` is `12.5`. So a temporal cell fell
through both branches of `mytryparse(::Type{MyTemporal}, …)` and was reported as "wrong start
format" — while the *same instant written as a number, with the same stray spaces*, parsed fine.
A hand-edited spreadsheet cell was enough to trigger it.

`MyTemporal` now trims for itself. The general lesson is the one the comment above it had got
wrong: "the parsers tolerate whitespace already" was true of every cell type except the one that
had no test asserting it. `NTuple{2,Int}` had a surrounding-whitespace case from the start;
`MyTemporal` did not, which is exactly why the gap survived. Both are pinned now.

**The trimming is in two layers, and neither is redundant.** `read_rows` reads with
`stripwhitespace = true`, and the cell parsers keep their own `strip`. Measured on CSV 0.10.16:

| written in the csv | reader alone | parser alone |
|---|---|---|
| `␣00:01:30␣` unquoted | trimmed | trimmed |
| `"␣00:01:30␣"` **quoted** | **untouched** | trimmed |
| whitespace-only cell | becomes `missing` | `filled` already treated it as absent |
| header `start␣` | **`:start`** | **unreachable** |

CSV treats quoting as "this value is literal" and does not strip inside it, so the reader is not a
superset of the parsers — dropping their `strip` would reintroduce the bug for any writer that
quotes padded fields (LibreOffice's "quote all text cells" export does). Julia's own `CSV.write`
does not quote them, and `test/harness.jl`'s `csvcell` quotes only on comma-or-quote, so the test
fixtures exercise the unquoted path only.

The header is the half that only the reader can fix, and it was its own latent bug: a column
written `start ` arrived as `Symbol("start ")` and was rejected as an unrecognized column — a loud,
accurate message about a cause invisible in the user's spreadsheet.

### `resolve_defaults` catches exactly two exceptions (#34)

`convert` has no non-throwing counterpart, so validating caller-supplied defaults stays a caught
exception. Over every whitelisted target type a rejected value fails as either a `MethodError` (no
such conversion: `"yes"` → `Bool`) or an `InexactError` (a lossy one: `1.5` → `Int`, `2` → `Bool`).
Anything else is not a rejected default and propagates.

### What may be set globally, and what may not

The `defaults` kwarg whitelists exactly the parameters each gateway's consumer takes — the eight
`Tuning` fields for runs, the builder keywords for rectifications. Identities and anchors
(`calibration_id`, `file`, `extrinsic`, `matlab_file`, `extrinsic_index`, `path`), scene points
(`center`, `north`), the temporal windows, `aspect`, and `only_scale`'s `scale` are all inherently
per-row. A default of `missing` means "imputed from the probed video", so a caller-supplied value
still beats the probe on every row whose cell is blank.

---

## Testing

### The corrupt-video fixture is deterministic

It used to be `rand(UInt8, 500)`, which made every corrupt-video test a dice roll: roughly one
random blob in 300 is recognised by ffprobe as some container, whereupon it exits 0 and reports
nothing usable rather than failing. That input is real and the code must handle it, but it has no
business arriving at random — it is now covered deliberately by the audio-only case in
`test/probing.jl`, while the fixture always exercises the outright-unreadable path. Every corrupt
fixture now comes from that one generator; `test/probing.jl` and the AprilTag tests in
`test/fromage.jl` each used to build their own.

### Ground truth is analytic

The tracking fixtures render a disc following a closed-form trajectory with ffmpeg's `geq`, encoded
losslessly (`-qp 0`) so the analytic ground truth stays exact with no encoder noise around the
disc. Tests assert RMSE against that closure rather than against recorded output.

The same principle runs through the pure unit tests: they assert invariants (`image2real` and
`real2image` are mutual inverses; a north point lands on the negative x-axis; a regular grid
measures its own spacing) rather than hard-coded matrices.

### Tests assert behaviour, not mechanism (#68)

Four tests used to state their subject in terms of the implementation that happened to satisfy it,
and were removed or rewritten for that reason:

- `test_module_state.jl` round-tripped `set_read_limit!` against `read_limit()`. That is a getter
  and a setter agreeing with each other; it could not fail while the code compiled.
- `test_concurrency.jl` acquired `READ_SEM[]` from sixty-four nested tasks and asserted the peak
  count never exceeded the limit. That is a test of `Base.Semaphore`, not of this package. What
  actually needs protecting is that concurrent reads come back *correct*, which is now asserted in
  `test_frame_reads.jl` by reading the same frame from sixty-four tasks and requiring every one to
  equal the frame a lone reader gets. Nothing asserted how the bound was implemented, so removing
  the semaphore outright cost exactly one edit — deleting the loop that swept the limit — and the
  correctness assertion it guarded still stands, now over unbounded concurrency as in production.
  Behaviour-shaped tests survive the deletion of the mechanism they were written against; that was
  the claim, and this is the case that tested it.
- `test_ffmpeg_cmd.jl` walked `Cmd.exec` asserting that `-ss`, `-frames:v` and `rawvideo` were
  present and `-vf` was not. Any reordering or reformulation of the command broke it, while a
  command that was well-formed and wrong still passed. The observable claims — the frame has the
  frame's shape, the timestamp is honoured, a `gblur` actually smooths the image, building the
  command does not mutate global `ENV` — moved to `test_frame_reads.jl`. `_vf` itself stayed a
  direct unit test (`test_vf.jl`): it is pure, and the two absent-value conventions it reconciles
  are worth pinning exactly.
- `eltype(parent(parent(stack)))` pinned how many view layers wrap the background stack. #27 is
  about the storage being 8-bit, not about the depth of the pipe, so the tests now recurse on
  `parent` to the fixpoint and check the array they land on.

The rule this leaves behind: a test may reach for an internal function, but what it asserts about
it has to be something a caller could observe.

### Each suite runs in its own wrapper module

Their suite-specific names — `DATADIR`, `ART`, `HEADER`, `check` — would otherwise collide.
Testsets nest fine across module boundaries, since they use the task's dynamic scope rather than
lexical scope.

### Shared test code is a module, not an `include` (#68)

`test/common.jl` was textually included into all four suite modules, which meant four compiled
copies and, worse, three of its definitions resolved a name belonging to whichever module included
them: `_merge` called that module's `row`, `load_capturing` called its `check`, and `write_csv`
took its `HEADER` as a default. Reading `common.jl` did not tell you what those calls did.

It is now two modules, split by who needs them. `test/fixtures.jl` holds the synthetic media — the
ffmpeg generators and the analytic ground truth that comes with them — plus the ffprobe readers,
and all four suites use it. `test/harness.jl` holds the CSV plumbing: `csvcell`, `write_csv`,
`buildrow`, `flagged`, and `capturing`, which now takes the thunk instead of reaching for `check`.
Only the two gateway suites use it; the tracker and end-to-end suites no longer compile it at all.
Each suite declares its `DATADIR` before including its `helpers.jl`, so artifacts and entry points
read top to bottom with nothing resolved late.

What did *not* move is the per-suite half. The plan had been to parameterise one harness by
(loader, header, artifacts) so both gateways shared their entry points. Written out, the factory
plus the unpacking each suite needs came to more lines than the five each suite spends now on
`row`, `write_csv`, `check`, `load_capturing` and `clean` — and it hid which loader a given `check`
reaches. Two short explicit definitions beat one shared indirect one here.

### Fixture encoding is not what makes the suite slow

Encoding each shared video once and copying it, rather than re-encoding the same content per suite,
was on the table: roughly 19 of the ~45 ffmpeg invocations produce content another suite has
already built. Timed, the entire generator set costs about 2.5 s — against `quality` (Aqua and
ExplicitImports) at 71 s, `PawsomeTracker` at 56 s and `Rectifications` at 26 s. A fixture cache
would have added machinery to save well under 1% of the run, so the duplicate encodes stay.

### Scenario csv names are generated, not invented (#68)

Every gateway scenario is loaded as its own csv, so each of 255 `check` calls used to open with a
hand-invented filename: `v_ncorn11.csv`, `p_center_ovf.csv`, `s_dupyadif.csv`, `t_sar2_c.csv`. The
name encoded nothing the row beside it did not already say, it had to be unique within `DATADIR`,
and inventing one was a step between having a case and writing it.

`check(rows; …)` now generates `case_N.csv` from a counter. The two-argument form stays for a test
that is about the file itself. What each line says is now only the thing being tested:

```julia
@test flagged(check([videorow(n_corners = (1, 1))]), 1, "n_corners must all be at least 3")
```

What this deliberately is *not* is a table driver. Turning these into `(override, message)` rows
would swallow the per-case comments — which are load-bearing arithmetic, not archaeology, and were
kept for that reason when the test comments were trimmed — and would report a failure against the
loop rather than the case. The shape was already a table; it just had a redundant column.

Three loops that built their names by interpolation (`"vm_$name.csv"`) gained a `@testset "$name"`
instead: the variable existed only to name a file, and two of the three loops had no per-iteration
testset at all, so a failure did not say which case produced it.

### JET runs on an allowlist of Julia minors, not on all of them

JET couples to compiler internals, so a new Julia release must not be able to break the suite
through it. The gate in `runtests.jl` is therefore an allowlist — currently `(1.11, 1.12)`, both
already in the CI matrix — and not a lower bound: a minor nobody has vetted runs no JET at all,
rather than running it and going red for a reason no change in this repo caused.

It was a single pin (1.11) until 1.12 was shown to be clean. Keeping it a single pin had a cost
that only showed up when someone looked: 1.12's inference reported `protect` and `keep` as
possibly-undefined in both tracking loops, and 1.11 did not, so the finding sat in `main`
invisible to CI. It was real, if unreachable — the variables were assigned under `if subtract` and
used under a second `subtract` test, and nothing but the correlation between two reads of one flag
made that safe. No test could have tripped it, because no execution can.

So the two halves belong together: the loops now assign unconditionally
(`protect, keep = subtract ? … : (nothing, nothing)`) and guard the restore on the value
(`isnothing(protect) || …`), which states the correlation instead of implying it; and 1.12 joined
the allowlist so that this class of finding surfaces in CI rather than on whoever happens to run
JET locally. Adding a further minor means checking it is clean first, then listing it.

The unconditional assignment is free. The `Union{Nothing,…}` union-splits, leaving no union in the
loop body, and costs nothing when `subtract` is off — measured against the alternative of an
always-concrete empty region, which allocates an empty slice every frame instead.

### The precompile workloads are excluded from coverage

They run during precompilation, which the coverage run does not instrument, so they can never be
hit by the test suite no matter how well the package is tested. Both workloads point at
nonexistent files, so they exercise the full parse + verification path but bail before any
ffprobe, `matread` or corner detection — no bundled media, fast and deterministic.

### The loop that produced #201–#204, and why each step stayed

Four structural changes shipped in a row under the same four-step loop. It is recorded because
every step earned its place by catching something the step before it could not, and skipping any of
them was tried at least once.

**1. Grill the design before writing code.** Rounds of questions with recommendations, waiting for
answers, before any edit. This is what surfaced what inspection had missed: that "family A" was two
shapes and not one, that the frame-centre pair was not an exact duplicate, and that family C was
nearly empty. Going straight to code skipped nothing useful in four attempts — it only moved the
discovery later, when it was more expensive.

**2. Measure the premise before building on it.** Transpose one argument pair at one call site, on
unmodified `main`, run the relevant subset, record what happens. That is what turned "this looks
risky" into "two of the four transpositions are invisible to the suite", and in #203 it found a
defect class no fixture in the repo could catch. The mutation tables in this file are the output of
exactly this step; treat "the suite would catch that" as a hypothesis until one of them says so.

**3. Mutation-check the new assertions too.** After extracting a function, transpose each one in
turn and confirm that *exactly* the intended test fails. This caught a test whose comment claimed to
pin `ref_sz` and did not — see "What the tracker's argument lists still do not pin".

**4. Gate on the suite, JET and allocations — not the clock.** See the benchmarks section below for
why wall-clock time on this machine cannot carry a claim.

## Benchmarks

### Two tiers, because one sampling strategy cannot serve both (#68)

`benchmark/benchmarks.jl` defines a single BenchmarkTools `SUITE`, which is the only thing the
runner has to agree on — AirspeedVelocity (`benchpkg Fromage --rev=main,my-branch`) and
PkgBenchmarks both read it, so the choice stays reversible. It is deliberately not wired into CI:
the suite already runs a full ffmpeg workload on every PR, and benchmark numbers from a shared
runner would be noise presented as data.

The `"micro"` group is pure, in-memory and deterministic — lens distortion forward and inverse,
the rectification's coordinate maps, the AprilTag ground geometry, and the detection filter.
BenchmarkTools samples these properly and the numbers mean what they say, so this is the tier that
can settle a design question.

The `"macro"` group is whole pipelines: `track` over the shared disc fixture, the same with a
diagnostic video, and `main` over a one-calibration, one-run data folder. These decode video,
spawn ffprobe and encode an `.mp4`, so a sampled statistic would be measuring the filesystem and
the scheduler rather than the code. Each runs once (`samples = 1, evals = 1`) and reports wall
clock and allocations — a regression tripwire, not a measurement.

Fixtures come from `test/fixtures.jl`, so a benchmark and a test measure the same synthetic media.

### The price of staying out of CI is that the suite rots silently (#206)

`@benchmarkable` builds an expression rather than evaluating the call, so `SUITE` *constructs*
against an API that no longer exists and only throws when the group is actually run. That is how
the gateway group came to call `load_runs`/`load_rectifications` with the `strict` keyword #185 had
removed, in the very commit that removed it (`69bf292`), and keep doing so across 22 releases
(v0.2.20 through v0.2.42): nothing constructed wrong, and nothing in CI ran it. The group was
therefore unrunnable throughout #201–#204 and #209 — precisely the work whose allocation claims it
existed to check.

The fix is a keyword swap, not a policy change: the group now calls `check_runs` /
`check_rectifications`, which is what `strict = false` meant, and the keys are renamed to match so
a key never again names an entry point the benchmark does not call. Measured either side of #185
with the fixture held identical, the split itself is free — 54,948 → 55,011 allocations on runs,
8,372 → 8,372 on rectifications — so the swap changes what is measured not at all. **Today's
anchor, same machine, 2026-09: `check_runs` ~54,200 allocations / 3.06 MiB, `check_rectifications`
8,339 / 400.60 KiB.** The runs count is the one that wobbles, by a couple of hundred (~0.2%) run to
run; the rectification count has been bit-stable across every run here. So a runs delta under about
half a percent is noise, and the 54,948 → 55,011 above is inside it.

Keeping benchmarks out of CI is still right for the reason above, so **this failure mode is not
designed away, it is accepted**: the mitigation is to run the suite when touching the code it
covers. #31 asked for BenchmarkCI to close the gap and was declined for the wall-clock reason
below, so nothing automated is coming. The same class of rot lives in
`test/tolerance_residuals.jl`, which `runtests.jl` also does not include: its apriltag section is
unreachable dead code, broken in three independent places, and its `main` swallows a section's
failure into one `SKIP` line either way (#220).

### What the benchmarks cannot tell you

Nothing in `benchmark/` touches a network filesystem. The threading shape in `track` and `main`
exists to survive EAGAIN on a CIFS share under concurrent ffmpeg reads — a contention failure
against a network filesystem, not a throughput number. No local benchmark reproduces it, so the
threading work has to be measured by a hand-run against the real data.

### `detect` is measured through `imfilter!`, not directly

Benchmarking `detect` itself would mean reconstructing a `Tracker`, a background stack and an open
`Video` from package internals — and would need rewriting by exactly the change it exists to
judge. What the threading question actually turns on is one call: `imfilter!` over a search window
a few tens of pixels wide. That is benchmarked directly, against the serial algorithm on the same
window and kernel, with the tracker's own shapes (a 10 px target, a 21×21 window) and no internals
in the way. End-to-end throughput is covered by the `"macro"` group.

The first run answered the question it was built for. On 32 threads, `CPUThreads` and `CPU1` come
out within 1% of each other (282 μs against 284 μs): the innermost layer of parallelism buys
nothing at this window size, and has since been removed. Both are still benchmarked, because that
comparison is the evidence for the choice. The same run priced the other open question — the bisection inverse
costs 274 μs per 640 pixels against 3.3 μs for the forward map, about 428 ns a pixel, which is the
budget a polynomial root has to beat.

### Wall-clock benchmarks on this machine are noise; read the allocations

Two runs of *identical* code on this machine have differed by up to 43% — `real2image` −43.5%, the
DoG filter −34% — with nothing changed between them. The `main` macro benchmark drifts by roughly ±5
allocations and a few tenths of a megabyte run to run for the same reason. This is not a property of
the code; it is the machine, and it does not average out at the sample counts these benchmarks use.

The failure mode is not a missed improvement, it is a fabricated one. A swing of about this size was
read as a real gain in #203 and had to be retracted in #204. Nothing was wrong with the benchmark:
the number was real, it just measured the machine rather than the change.

**So the stable signal is allocations** — on the `"micro"` group and on the two `track` benchmarks —
and that is what a design claim has to rest on. A wall-clock difference is worth acting on only if
it survives a re-run of both sides and is far larger than the spread above. This sits *under* the
two-tier rule: the `"macro"` group still cannot settle a design question, whatever it reports.
