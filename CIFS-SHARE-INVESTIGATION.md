# Reading video off the CIFS share: what we measured

**Date:** 2026-08-19 · **Package:** Fromage.jl at `main` (post-#85) · **Context:** GitHub issue #68,
candidate 06 — "flatten the threading to one level per stage and delete `READ_SEM`"

This is a record of a day's measurement against real field data on the lab's CIFS share. It exists
because the code carries a global read limiter (`READ_SEM`, `set_read_limit!`, `read_limit`, an
`__init__`, and a `RECTIFICATIONS_READ_LIMIT` environment variable) plus a retry-with-backoff loop,
both justified in comments by "EAGAIN on the share", and nobody had measured whether either was
still needed or what it cost.

**Short version.** The limiter is not needed and costs a little speed. The retry loop *is* needed:
without it roughly 7% of rectification stages abort, and they abort with a message that blames the
user's data. The threading structure the candidate targets is 7.6% of the run; the other 89% is
tracking, which is bandwidth-bound and is made *slower* by the current thread count. Underneath all
of it sits a mount that has reconnected over a thousand times, which is probably the real problem
and is not an application-level problem at all.

Everything below is reproducible; the commands and scripts are described well enough to rebuild.

---

## 1. Environment

### 1.1 The mount

```
//uw.lu.se/research/LU25D1044-Dacke_Lab on /home/yakir/mnt type cifs
  vers=3.1.1, cache=strict, soft, nounix, mapposix,
  rsize=4194304, wsize=4194304, bsize=1048576,
  actimeo=1, closetimeo=1, echo_interval=60,
  uid/gid forced, file_mode=0777, dir_mode=0777
```

Three SMB sessions are open, to three different hosts:

| # | ConnectionId | Hostname |
|---|---|---|
| 1 | 0x4 | lces1133cs.uw.lu.se |
| 2 | 0x3 | WFS425N15.uw.lu.se |
| 3 | 0x2 | uw.lu.se |

From `/proc/fs/cifs/Stats` at the start of the day:

```
1003 session 1886 share reconnects
Max requests in flight: 278
Total vfs operations: 392801   maximum at one time: 87
```

**One thousand session reconnects is the single most important number in this document.** It is not
a rate we caused; it is the standing state of the mount. Everything else here is downstream of it.

### 1.2 The client

- 32 Julia threads (`JULIA_NUM_THREADS=auto`), Julia 1.12.7
- `ulimit -u` = 514567, `ulimit -n` = 1048576 — **local process and descriptor limits are nowhere
  near being a factor.** This matters because "Resource temporarily unavailable" (EAGAIN) is also
  what `fork()` returns at `RLIMIT_NPROC`, and that hypothesis is ruled out.

### 1.3 The dataset

A real session: `Q4 Overcast & tree orientation/> calibration` (note the literal `>` in the
directory name — quote paths carefully).

- **14 calibrations** — 12 `video` type, 2 `only_scale`
- **372 runs**
- **14 distinct videos**, each 1920×1080, 50 fps, H.264, ~4736 s (79 min), **~27.6 GiB**
- Videos live in sibling directories (`../A1. clear no_trees CW/videos`), reached via the `path`
  column
- Calibration windows are 20–38 s; with the default `temporal_step = 2.0` that is 11–20 intrinsic
  frames per calibration, **~183 frames total**
- Run windows: median 12 s, min 4 s, max 72 s, **4,978 video-seconds in total**

Invocation under test throughout:

```julia
Fromage.main(data_path; tracking_defaults = (scale = 0.3, fps = 5, target_width = 40))
```

### 1.4 An incidental finding: one video is corrupt

`C3. clear dense_trees dance/videos/20251125-0909.MP4` is 19.5 GB and **has no moov atom**. It fails
at every timestamp, serially, in isolation — `Invalid data found when processing input`. It is *not*
referenced by `calibs.csv` or `runs.csv`, so it does not affect the pipeline, but somebody should
know. All other 42 videos in the tree read fine.

This matters for a second reason: it is the same error text a *transient* share failure produces
(see §7), which makes the two indistinguishable from the log.

---

## 2. Baseline: where the time actually goes

One full pipeline run, unmodified `main`, semaphore at its default of 12, retries enabled:

**693.4 s wall · 372 runs · zero errors · Δsession reconnects 1 · Δshare reconnects 2**

| stage | time | share of run |
|---|---|---|
| Parsing `calibs.csv` | ~0 s | — |
| Parsing `runs.csv` | ~0 s | — |
| Reading runs videos (ffprobe) | 1 s | 0.1% |
| Reading calibration videos (ffprobe) | 2 s | 0.3% |
| Validating extrinsics | 3 s | 0.4% |
| Validating intrinsics | 10 s | 1.4% |
| **Building rectifications** | **38 s** | **5.5%** |
| **Building runs (tracking)** | **618 s** | **89.1%** |
| remainder (concat, csv writing) | ~21 s | 3.0% |

**The entire semaphore-guarded read path — every `_frame_at` call, all the nested `tmap` layers,
the whole subject of candidate 06 — is 53 s of 693, i.e. 7.6%.** Tracking is 89%, and tracking uses
a completely different read mechanism (`VideoIO.openvideo`, one open per run) that never touches the
semaphore.

Any optimisation of the rectification read path is therefore bounded at ~7% of the run before it
starts. This should have been measured before the candidate was written; it reframes the whole
exercise.

**Data safety:** a manifest (path, size, mtime) of all 927 files under the data root was taken
before and after every run in this investigation. It was byte-identical every time. The pipeline
writes only to `results_dir` relative to the *current working directory*, so all runs were executed
from a scratch directory.

---

## 3. What the share can actually do

### 3.1 Single frame read

The pipeline's unit of work on this path is one ffmpeg process per frame:

```
ffmpeg -hide_banner -loglevel error -ss <t> -i <file> -frames:v 1 -f rawvideo -pix_fmt gray pipe:1
```

Measured on a 27.6 GiB file:

| timestamp | time |
|---|---|
| 10 s | 712 ms |
| 12 s | 676 ms |
| 34 s | 511 ms |
| 40 s | 627 ms |
| 600 s | 654 ms |
| 2000 s | 548 ms |
| 4000 s | 643 ms |
| 34 s (repeat ×3) | 528 / 507 / 508 ms |

**~500–700 ms, flat with respect to timestamp**, and repeating the same timestamp does not get
cheaper. So the cost is the open plus header read, not the seek, and the client is not caching
anything useful between processes. `ffprobe` on the same file costs ~0.4 s.

### 3.2 Concurrency, one file

48 reads at distinct timestamps, varying the number in flight:

| K | wall | reads/s | median latency | errors |
|---|---|---|---|---|
| 1 | 31.08 s | 1.54 | 599 ms | 0 |
| 2 | 12.32 s | 3.90 | 499 ms | 0 |
| 4 | 7.19 s | 6.67 | 582 ms | 0 |
| 8 | 4.87 s | 9.85 | 761 ms | 0 |
| 12 | 4.24 s | 11.32 | 997 ms | 0 |
| 16 | 4.24 s | 11.32 | 1294 ms | 0 |
| 24 | 4.00 s | 12.00 | 1760 ms | 0 |
| 32 | 4.07 s | 11.80 | 2367 ms | 0 |
| 48 | 3.92 s | 12.23 | 3629 ms | 0 |

Throughput saturates at **~12 reads/s** somewhere around K=8–12, after which latency grows linearly
with K for no gain. The default `READ_SEM` limit of 12 sits almost exactly on the knee, which is a
good choice for throughput — but note **zero errors at every level**.

### 3.3 Concurrency, 42 distinct files

128 reads spread across all healthy videos:

| K | wall | reads/s | median latency | errors |
|---|---|---|---|---|
| 12 | 23.65 s | 5.41 | 1863 ms | 0 |
| 32 | 19.82 s | 6.46 | 3654 ms | 0 |
| 64 | 16.61 s | 7.71 | 5965 ms | 0 |
| 96 | 16.86 s | 7.59 | 8223 ms | 0 |
| 128 | 16.56 s | 7.73 | 10737 ms | 0 |
| 192 | 16.18 s | 7.91 | 10527 ms | 0 |
| 256 | 15.00 s | 8.53 | 9414 ms | 0 |

Two things stand out. Spreading over many files is roughly **half the throughput** of hammering one
file (5.41 vs 11.32 reads/s at K=12) — each distinct file needs its own open and header read on the
server. And again, **zero errors, all the way to 256 concurrent ffmpeg processes.**

**We could not reproduce EAGAIN by concurrency alone.** Whatever the original comment described, it
is not "exceed N concurrent reads and you get EAGAIN".

### 3.4 Raw bandwidth

Using `dd` at cold offsets:

| streams | aggregate |
|---|---|
| 1 | **96.2 MB/s** |
| 4 | 62 MB/s |
| 8 | 71 MB/s |

**Concurrency reduces total bandwidth on this share.** A single sequential stream beats eight
concurrent ones. This is the opposite of the assumption that more threading is better, and it
governs the tracking stage (§5).

---

## 4. The failure mode is not EAGAIN — it is an SMB2 credit stall

During a tracking scaling test (at `ntasks = 2`, i.e. *low* concurrency), the process wedged. The
diagnosis:

```
$ cat /proc/fs/cifs/DebugData
Active VFS Requests: 2
Number of credits: 0     Dialect 0x311 signed nosharesock     <-- this session
Number of credits: 193   Dialect 0x311 signed nosharesock
Number of credits: 193   Dialect 0x311 signed nosharesock
```

Two threads sat in state **`D` (uninterruptible sleep)** with wchan `smb2_wait_mtu_credits`,
consuming **0 CPU ticks over a 5-second sample**, and still there ten seconds later. It persisted
for **over 21 minutes**. `kill -9` on the process had no effect until the outstanding SMB operation
returned. Five session reconnects were recorded during that test.

SMB2/3 uses a credit system to bound outstanding requests. If a session's credits reach zero — and
reconnects are a way to lose them — the client blocks *before sending*, indefinitely. The `soft`
mount option does not help, because `soft` governs what happens to a request that times out, and
here the request is never issued.

After the process was killed, the session recovered on its own (credits went 0 → 1623) and reads
resumed at 71 MB/s.

**Implications:**

1. The dangerous failure on this share is a **hang**, not a retryable error. A hang is worse: it is
   uninterruptible, it does not appear in any log, and it does not respond to `kill`.
2. It occurred at concurrency 2. It is therefore not obviously a function of how many reads we
   issue, which weakens the argument that a concurrency limiter protects against it.
3. It is almost certainly downstream of the mount's chronic reconnecting.

**We were unable to reproduce this deliberately.** It happened once in roughly three hours of heavy
use. Anyone continuing this work should treat reproducing it as a primary objective, because
without a reproduction there is no way to test a fix.

---

## 5. Tracking: the 89%, and it is bandwidth-bound

Tracking must transfer the bytes of every run's window:

- 4,978 video-seconds × 6.3 MB/s of video = **31.2 GB**
- At the measured 62–96 MB/s, the network floor is **325–503 s**
- Observed: **618 s**

So tracking runs at 53–81% of what the network permits. It is not thread-bound; it is pipe-bound.
No restructuring of `tmap` layers can beat the floor.

### 5.1 It is over-threaded

28 runs, stratified across all 14 videos (one per video, then a second per video, and so on):

| ntasks | wall | speedup |
|---|---|---|
| 1 | 98.0 s | 1.00× |
| 2 | 57.9 s | 1.69× |
| 4 | 51.6 s | 1.90× |
| **8** | **50.8 s** | **1.93×** |
| 16 | 78.7 s | 1.25× |
| 28 | 75.6 s | 1.30× |

**There is an optimum near `ntasks = 4–8`, and the current code runs this loop at
`ntasks = nthreads = 32`, which is ~50% slower than the optimum.** Extrapolated to the full run
that is on the order of **200 s of the 693 s**, i.e. ~29% — an order of magnitude more than
everything else in this document combined.

This was *not* measured to completion: the run that would have confirmed it across three rounds is
the one that hit the credit stall in §4. **This is the single highest-value follow-up.**

A caution for whoever repeats it: an earlier version of this test used `rs[1:32]`, which are all
runs on *one* video (A1.a alone has 114 runs). That gave erratic, meaningless numbers. The
selection must be stratified across files.

---

## 6. The batched read: correct, and not faster

Hypothesis: replace one ffmpeg process per frame with one process per calibration window, so the
share sees ~12 opens instead of ~183.

### 6.1 Getting the frames right

Three selection strategies, compared against the per-frame reads they would replace (16 frames from
A1.a's window):

| strategy | wall | frames identical |
|---|---|---|
| `fps=1/step` | 5.20 s | **0 / 16** |
| `select` on elapsed time (`gte(t-prev_selected_t,step)`) | 5.27 s | 4 / 16 |
| **`select=not(mod(n,stride))`, stride = step × fps** | 5.32 s | **16 / 16** |

Selecting by **frame number** is bit-for-bit identical to the per-frame reads. Selecting by *time*
drifts: the observed mean absolute pixel differences (13–29 of 255) correspond to Δt ≈ 0.5–1.5 s,
calibrated by comparing frames deliberately offset in time (Δt=0.02 s → 0.76; Δt=0.5 → 12.1;
Δt=1.0 → 17.3; Δt=2.0 → 21.7).

Verified across **all 12 video calibrations: every frame identical**, correct counts (16/16, 17/17,
14/14, 15/15, 20/20, 18/18, 20/20, 13/13, 14/14, 11/11, 11/11, 14/14).

Two implementation details that cost 2× if you get them wrong:

- **Filter order.** `select` must precede the caller's `-vf`. With `gblur,fps` ffmpeg blurs all
  ~1500 decoded frames and then throws away all but 16 (9.32 s); with `select,gblur` it blurs only
  the survivors (5.26 s). The decode-only floor for the window is 5.08 s.
- **Escaping.** The comma inside `mod(n\,stride)` must survive Julia string escaping *and* ffmpeg's
  filter parser. Single quotes around the expression are wrong here — there is no shell, so they are
  passed literally and silently break the expression (it then selects consecutive frames, which
  looks like a fast success).

### 6.2 It does not make the pipeline faster

Isolated, one window: per-frame 10.19 s vs batched 5.32 s — **1.92×**.

Twelve calibrations concurrently, read portion only:

| approach | run 1 | run 2 |
|---|---|---|
| per-frame (current) | 31.8 s | 31.3 s |
| batched, ffmpeg default threads | 28.9 s | 29.1 s |
| batched, `-threads 1` | 32.5 s | 32.6 s |
| batched, `-threads 2` | 31.3 s | 28.7 s |
| batched, `-threads 4` | **28.2 s** | **27.8 s** |
| batched, `-threads 8` | 29.9 s | 29.3 s |

And at the stage level, as the pipeline actually runs it (`tmap` over calibrations):

| | tmap wall | summed per-calibration work |
|---|---|---|
| main (per-frame) | 39.7 s | 422.8 s |
| batched | **39.8 s** | **318.3 s** |

**Identical wall clock. 25% less total work.** The stage is latency-bound and already fully
overlapped by running 12 calibrations concurrently, so doing less work per calibration does not
shorten it. The isolated 1.92× is real but is already being harvested by concurrency.

### 6.3 Correctness of the resulting calibrations

Rectification maps (image2real evaluated over a 30-point grid, all 14 calibrations) agree with
`main` to **max 1.22e-6 real units ≈ 1.2e-5 pixels**. Not bitwise, but far below anything physical:
tracking RMSE is ~1 px.

The residual difference is float noise in OpenCV's iterative `calibrateCamera`, reached via slightly
different thread scheduling. Both code paths are internally deterministic — verified by running each
twice and diffing (main vs main: identical; branch vs branch: identical).

**Verdict: the batched read works and is not worth landing on speed grounds.** It is preserved on
branch `batched-intrinsic-reads` (commit e011f86) for reference.

---

## 7. Removing the semaphore, and removing the retries

### 7.1 Removing `READ_SEM` alone is safe and slightly faster

Varying only the limit, three interleaved rounds of the build stage:

| `read_limit` | round 1 | round 2 | round 3 | best |
|---|---|---|---|---|
| 12 (default) | 37.9 s | 33.6 s | 34.3 s | 33.6 s |
| unbounded | 27.8 s | 26.1 s | 27.0 s | 26.1 s |

Repeated more carefully — six interleaved iterations of load + build, which is the honest
comparison:

| | load (med) | build min/med/max | total (med) | peak ffmpeg | failures |
|---|---|---|---|---|---|
| `limit = 12` | 26.1 s | 33.0 / 34.8 / 38.0 | 60.0 s | 24 | 0 / 6 |
| unbounded | 24.8 s | 28.5 / 31.8 / 37.7 | **57.3 s** | 48 | 0 / 6 |

**~5% faster overall (9% on the build stage), faster in 5 of 6 paired iterations, zero failures.**
An earlier single measurement suggested 22%; that was a lucky minimum and is withdrawn.

Note the peak concurrency without the limiter is only **48**, not the ~180 one might expect from
12 calibrations × 15 frames — OhMyThreads' `tmap` chunks by thread count rather than spawning a task
per element. 48 is comfortably inside the 256 that produced no errors in §3.3.

Three full pipeline runs with the limiter effectively removed: **744.6 s, 689.3 s, 699.9 s**, 372
runs each, zero errors, peak 48 ffmpeg processes, 1–2 session reconnects each. Against the 693.4 s
baseline this is entirely within run-to-run noise.

### 7.2 Removing the retries as well: ~7% of runs abort

Configuration: **no semaphore, no retry loop, batched reads** — the arrangement we most wanted to be
true.

| soak | iterations | failures | rate |
|---|---|---|---|
| A | 40 | 3 | 8% |
| B (diagnostic) | 18 | 1 | 6% |
| **combined** | **58** | **4** | **~7%** |

Each iteration is one `load_rectifications` + build, roughly 60 s and ~200 frame reads. So the
underlying transient read-failure rate is on the order of **one failure per 2,500–3,000 reads**.

The failure, captured verbatim:

```
row=1 id=A1.a :: issue with corner detection in the calibs window:
                 ffmpeg could not read the frame (the file is corrupt, truncated, or not a video)
row=2 id=A1.b :: issue with corner detection in the calibs window: ...
```

Three observations:

1. **Batching did not prevent it.** The hypothesis that fewer, larger reads would remove the need
   for retries is disproved: all these failures occurred *with* batched reads. Batching cuts the
   number of opens ~15× but lengthens each one, so total time-exposed-to-a-hiccup does not fall.
2. **It hits several calibrations simultaneously** (A1.a and A1.b in the same iteration), which is
   the signature of a share-wide transient event catching everything in flight — not one unlucky
   file.
3. **The error blames the data.** Without the retry, a network hiccup is reported as *"the file is
   corrupt, truncated, or not a video"*. Given there is a genuinely corrupt file in this tree
   (§1.4), that is actively misleading. Under `strict` (the default) it aborts the whole run.

### 7.3 What this means for the three goals

The goals were: (1) process as fast as possible, (2) delete `READ_SEM`/`set_read_limit!`/
`read_limit`/`__init__`, (3) zero errors.

| goal | verdict |
|---|---|
| 1 | The win is in **tracking**, and it comes from *reducing* concurrency (§5.1), not from this path |
| 2 | **Achievable.** The limiter earns nothing: 5% slower with it, 0 failures without it in 15 runs |
| 3 | **Requires the retry loop.** Without it, ~7% of stages abort |

The achievable configuration is therefore: **no semaphore, no global mutable state, retries kept.**

---

## 8. On "a read of a mounted file should never fail like that"

This is the right instinct, and this report should not be read as arguing otherwise. Everything in
§7.2 is the application coping with something that ought not to happen. The evidence that the
problem is below the application:

- **1009 session and 1892 share reconnects** accumulated on this mount, and 1–2 more per 11-minute
  run. A healthy SMB mount does not reconnect on that scale.
- The credit stall of §4 is a **kernel client** state (`smb2_wait_mtu_credits`, `Number of credits:
  0`), not something a userspace program can cause or avoid by issuing fewer reads.
- The failures in §7.2 arrive in **bursts across independent files**, which is what a transport-level
  event looks like.
- Throughput *falls* with concurrency (§3.4), which is unusual and may itself be a symptom.

**Recommended lines of enquiry for whoever picks this up**, roughly in order of expected value:

1. **Why is it reconnecting?** Correlate `/proc/fs/cifs/Stats` reconnect counters with `dmesg`
   (`CIFS: VFS:` lines carry the reason — timeouts, credential renewal, server restarts), and with
   server-side SMB logs. This is the root cause; everything else is a workaround.
2. **Mount options.** The current mount is `soft` with `actimeo=1`, `closetimeo=1`,
   `cache=strict`. Worth testing: `hard` (blocks rather than erroring — trades one failure mode for
   another, and interacts badly with the credit stall), a larger `actimeo`, `nostrictsync`, and
   `echo_interval`. Also whether SMB multichannel is in play across those three sessions.
3. **Reproduce the credit stall.** Without a reproduction there is no way to verify a fix. Try
   sustained high concurrency with deliberate session interruption.
4. **Compare clients.** Does a Windows or macOS SMB client against the same share show the same
   reconnect rate? That separates "the server/network" from "the Linux cifs client".
5. **Network path.** Three different hostnames are serving this mount; packet loss, MTU, or a
   flapping route to any of them would produce exactly this.
6. **Is it time-of-day dependent?** All measurements here were taken within a single working day.

If the mount can be made stable, the retry loop becomes dead weight and can be deleted — which is
the outcome originally wanted. **Nothing in the application can deliver that on its own.**

---

## 9. Measurement mistakes made along the way

Recorded because the next investigator will be tempted by the same ones. Every item here produced a
plausible, wrong number that was believed for a while.

1. **Sequential A/B.** Running all of arm A then all of arm B made a change look 21% slower.
   Interleaving the rounds showed the difference was machine load. *Identical minima with divergent
   upper quantiles is the signature.* Always interleave; report min and p25, not mean.
2. **Measuring the wrong parallelism.** A comparison script built rectifications with a sequential
   comprehension instead of `tmap`, so it reported the sum of per-calibration times (111 s) rather
   than the stage wall (39.8 s) — and made a no-op change look like a 3× regression.
3. **Comparing outputs with no control.** H.264 diagnostic videos differ byte-for-byte between two
   runs of *identical* code. Without running that control, the difference reads as a regression.
   The same applies to OpenCV fits (which turned out to be deterministic — but that had to be
   checked, not assumed).
4. **Unstratified sampling.** `rs[1:32]` are all runs on one video; a scaling curve built from them
   is meaningless. Stratify across files.
5. **`for round in 1:3`** shadows `Base.round`. The error surfaces far from the cause.
6. **A harness calling a function the branch had deleted** produced 40 "failures" in 45 minutes that
   were entirely self-inflicted. Add a fail-fast: if iteration 1 fails, abort and say so.
7. **`dd count=100` with `iflag=count_bytes`** copies 100 bytes, not 100 blocks, and reports a
   confident 66 kB/s.
8. **Filter order and shell quoting in ffmpeg** (§6.1) — both fail *silently and fast*, which reads
   as success.

---

## 10. What was not established

- Whether the retry-enabled configuration is genuinely 0% failure. We saw 0 in 15 runs against ~7%
  without; the direction is certain, the rate is not. A 40-iteration soak of the retry-enabled
  config (~45 min) would settle it.
- Whether the credit stall is reproducible, and what triggers it.
- Whether the predicted ~200 s saving from `ntasks ≈ 8` in tracking survives a full-pipeline A/B.
- Whether any mount option changes the transient failure rate.
- Whether these failures occur on other clients or at other times of day.
- Whether the two `tmap` layers inside verification, and the `Threads.@spawn` inside
  `Rectification`, matter at all — given the stage is 7.6% of the run, they were never worth
  measuring separately.

---

## 11. Reproducing this

Scripts used live in the session scratchpad, not in the repo. The essentials:

- **Reconnect counting.** Diff `/proc/fs/cifs/Stats` around any operation:
  `grep -oE "[0-9]+ session [0-9]+ share reconnects" /proc/fs/cifs/Stats`
- **Credit state.** `grep -E "Number of credits|Active VFS" /proc/fs/cifs/DebugData`
- **Detecting a stall.** Look for threads in state `D`:
  `for t in /proc/<pid>/task/*; do awk '{print $3}' $t/stat; done | sort | uniq -c`, and check
  `cat /proc/<pid>/task/<tid>/wchan`. Confirm with a CPU-tick sample — a stalled process shows 0
  ticks over several seconds while `ps` may report a misleading lifetime average.
- **Stage timings.** The pipeline's ProgressMeter output carries them; convert `\r` to `\n` and
  grep for `100%.*Time:`.
- **Data safety.** `find <root> -type f -printf '%s\t%T@\t%p\n' | sort` before and after; diff.

---

## 12. Recommendation

1. **Delete** `READ_SEM`, `set_read_limit!`, `read_limit`, `Rectifications.__init__` and the
   `RECTIFICATIONS_READ_LIMIT` environment variable. They cost ~5% on the stage they guard and
   prevented nothing measurable in 15 runs.
2. **Keep** the retry with backoff, and **fix its message** so a transient read failure is not
   reported as file corruption. Suggested: name it as a read failure that survived N retries, and
   mention the share, so it is distinguishable from the genuinely corrupt file in §1.4.
3. **Do not land** the batched read. It is correct but not faster, and it does not buy the
   robustness it was designed for.
4. **Do** pursue `ntasks ≈ 8` for the tracking `tmap` — it is worth ~29% of the total run, an order
   of magnitude more than everything else here. Measure it properly first (§5.1).
5. **Escalate the mount.** The application-level work is finished at ~5%; the remaining error rate
   is a filesystem problem and should be treated as one.
