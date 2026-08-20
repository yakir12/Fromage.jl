# Why frame reads fail without the retry

**Date:** 2026-08-20 · **Package:** Fromage.jl at `cifs-root-cause` · **Context:** follow-up to
`CIFS-SHARE-INVESTIGATION.md`, which established *that* ~7% of rectification stages abort without
the retry loop but not *why*, and left "reproduce it and find the mechanism" as the open question.

**Short version.** The failure is `open()` returning **EAGAIN**, and it is now captured verbatim
rather than inferred. It is not caused by our concurrency: 5,371 reads swept across concurrency 1
to 48 produced **zero** failures, while a *completely idle* minute of the same mount produced the
highest reconnect rate measured. The limiter was therefore deleted.

The retry is a different story from the one the previous investigation told. It is **not** covering
a steady ~7% of stages. In a 3.5-hour paired soak — **407,160 reads across four arms, 23 reconnects
— there were zero failures, and the retry never fired once**. It is dormant during normal
operation and costs nothing. What it covers is rare, severe episodes: one such episode, caught at
the very start of this work, failed 62 of 195 reads in a single 19-second window. So the loop is
not a workaround for a constant problem; it is cheap insurance against an intermittent one, and
the honest reason to keep it is that it is free, not that it is constantly needed.

---

## 1. The evidence nobody had

Every failure recorded in the previous investigation lost the one thing that identifies it.
`read(cmd)` lets ffmpeg's stderr through to the terminal and raises a `ProcessFailedException`
carrying an exit code and nothing else. The exit code was never read either — the failure was
classified only by its Julia type, and reported with a canned sentence asserting the file was
corrupt.

Replacing `read(cmd)` with a capture of both streams, the first bad window produced this, 62 times
in one 195-read iteration:

```
exit=245  signal=0  nbytes=0  dt=5.95s
[in#0 @ 0x1bc6a800] Error opening input: Resource temporarily unavailable
Error opening input file .../A1. clear no_trees CW/videos/20251119-1435.MP4.
Error opening input files: Resource temporarily unavailable
```

Three things follow immediately, and each kills a hypothesis:

1. **It is EAGAIN, and it is at `open()`.** `nbytes = 0`, "Error opening input". Decoding never
   starts, so "the file is corrupt, truncated, or not a video" describes a stage that never ran.
2. **`signal = 0` on all 62.** Nothing was killed. The OOM-killer hypothesis — plausible given 48
   concurrent ffmpeg processes against 27.6 GiB files under `cache=strict` — is dead.
3. **The open hangs 5–15 s first** (median 13.0 s), then fails. That is not a rejection and not a
   request timeout; it is the kernel abandoning a request already in flight.

### 1.1 The exit code is the errno, verified

ffmpeg returns the negated errno, so the exit status is `256 − errno`. This was checked against
deliberately provoked failures rather than assumed:

| errno | ffmpeg exit | observed |
|---|---|---|
| EACCES (13) | 243 | ✓ `Error opening input: Permission denied` |
| ENOENT (2) | 254 | ✓ `Error opening input: No such file or directory` |

So the field data decodes unambiguously:

| exit | errno | meaning | count in the burst |
|---|---|---|---|
| 245 | 11 | **EAGAIN** — Resource temporarily unavailable | 60 |
| 153 | 103 | **ECONNABORTED** — Software caused connection abort | 1 |
| 247 | 9 | **EBADF** — Bad file descriptor | 1 |

ECONNABORTED and EBADF are the signature of a connection torn down underneath a file handle. No
application can produce those by asking for too much.

The genuinely corrupt file in the tree behaves differently in a way that matters: it exits **183**,
which is not an errno at all (`256 − 183 = 73`) but `AVERROR_INVALIDDATA` truncated, and says
**`moov atom not found`**. The two failure classes were always distinguishable. The information was
just thrown away before anyone could look at it.

---

## 2. It is not our concurrency

The limiter's justification, in the code, was that "a burst of nested `tmap` tasks can't trip
EAGAIN". That is testable. Arms at concurrency 0 (idle control), 1, 4, 12 and 48, 60 s each,
**interleaved over four rounds** so that drift in the share's health cannot masquerade as an effect
of load:

| K | reads | failures | session reconnects/min |
|---|---|---|---|
| **0 (idle, no reads at all)** | 0 | — | **0.50** |
| 1 | 388 | 0 | 0.00 |
| 4 | 1,051 | 0 | 0.00 |
| 12 | 1,444 | 0 | 0.00 |
| 48 | 2,488 | 0 | 0.24 |

**5,371 reads, zero failures, at every concurrency the code can produce** — and the idle arm, which
issued no reads whatsoever, reconnected twice, the highest rate of any arm. Reconnects are not
something we provoke; they happen to a mount sitting still.

This closes the question the previous investigation left open at its §3.3 ("we could not reproduce
EAGAIN by concurrency alone"). EAGAIN is not reproducible by concurrency because concurrency is not
what causes it. The limiter was deleted.

### 2.1 And then 407,160 reads with nothing at all

The deliverable experiment ran four arms **paired in time**, alternating iteration by iteration in
shuffled order so all four met the same weather: the pipeline's 195-read workload with the retry,
the same without it, a bare `open()`+`pread`+`close` (no ffmpeg), and reads on handles opened once
at the start and held for the whole soak. 3.5 hours, 522 cycles:

| arm | reads | failures | reads needing a retry |
|---|---|---|---|
| ffmpeg, no retry | 101,790 | **0** | — |
| ffmpeg, with retry | 101,790 | **0** | **0** |
| bare `open()` | 101,790 | **0** | — |
| held handle | 101,790 | **0** | — |

23 reconnect events occurred during that window. None of them cost a single read.

Two conclusions, and one non-result:

1. **The retry never fired.** Not once in 101,790 reads. Whatever it costs, it is not paid during
   normal operation.
2. **"~7% of stages abort without the retry" is not a stable rate.** The previous investigation
   measured 4 aborts in 58 iterations; this soak measured **0 in 522**. The difference is the
   share's condition, not the code. Any number quoted as "the failure rate" is really a
   measurement of what the mount was doing that afternoon.
3. **The mechanism test did not fire.** `bare_open` versus `held_handle` was meant to settle
   whether an established handle survives what an in-flight `open()` does not — the most likely
   explanation for tracking's immunity (§3). With no episode during the soak, both arms sat at
   zero and the question is still open. It needs a soak that catches an episode, or a way to
   provoke one.

---

## 3. Why tracking never fails

Tracking is 89% of the run and moves ~31 GB, has **no retry, no catch, no backoff at all**, and has
never been observed to fail. That looks like a contradiction until you count opens rather than
bytes:

| stage | opens | over | open rate | concurrent | retry? | failures |
|---|---|---|---|---|---|---|
| tracking | 372 | 618 s | **0.6/s** | no — serialised under `OPENVIDEO_LOCK` | none | 0 |
| rectification | 195 | ~20 s | **10/s** | yes, up to 48 | 4 tries | the ones in §1 |

Tracking opens each video once and streams from the established handle. Rectification opens once
per *frame*. Since every captured failure is an `open()` failure with `nbytes = 0`, the exposure is
the open, not the transfer — which is also why the batched read tried in the previous
investigation did not help: it cut opens 195 → 12, but those 12 still fired simultaneously.

---

## 4. The mechanism

The mount is:

```
//uw.lu.se/research/LU25D1044-Dacke_Lab  vers=3.1.1, cache=strict, soft, actimeo=1, closetimeo=1
```

behind a two-level DFS chain (both referrals `ttl=1800`):

```
\uw.lu.se\research  (root)  →  \WFS425N15.uw.lu.se\research  (+7 sibling targets)
                            →  \lces1133cs.uw.lu.se\LU25D1044-Dacke_Lab$   ← the file server
```

Reconnects are overwhelmingly on the **file server**, not the DFS roots: `Instance: 975` on
`lces1133cs` against `73` on each of the other two. This is not referral churn; it is one server
dropping its connection, and it has done so about a thousand times.

`soft` is the operative mount option. On a soft mount the cifs client returns a timed-out or
reset request to userspace as an error; in-flight requests are marked `MID_RETRY_NEEDED` on
reconnect and surface as **-EAGAIN**. On a `hard` mount the kernel reissues them itself and the
application never sees anything. So:

> **The retry loop in `_read_frame` is a userspace reimplementation of what `hard` does in the
> kernel.** It exists because the mount asked the application to do the retrying.

### 4.1 But not every reconnect is a failure — and this is the part that is not established

It would be tidy to say "each reconnect kills the opens in flight", and the burst in §1 is
consistent with it: two session and four share reconnects inside the 19 s window that produced 62
failures, with the file server's credits resetting 1951 → 8192.

The tidy story is wrong, or at least incomplete. Over a subsequent **1 h 40 m of continuous heavy
load — roughly 125,600 reads at concurrency up to 48 — the file server reconnected seven times and
not one read failed**:

| counter | over that window |
|---|---|
| session reconnects | +15 |
| `lces1133cs` (the file server) `Instance` | +7 |
| DFS root servers | +4 each |
| **read failures** | **0** |

So reconnects are routine and mostly harmless, and something *else* distinguishes the destructive
event from the benign one. Candidates, none of them tested here:

- a full session teardown requiring re-authentication, versus a quick TCP re-establishment;
- credit exhaustion (the burst reset credits to 8192, i.e. the session was rebuilt from scratch),
  which is the same neighbourhood as the uninterruptible credit stall in
  `CIFS-SHARE-INVESTIGATION.md` §4;
- a server-side event — a restart or failover — that the reconnect counter merely reflects.

The 5–15 s hang before each failure is the strongest hint: a routine reconnect does not take five
seconds. Whatever happened at 00:21 held requests in flight for a third of a minute before
abandoning them.

**What is established:** the failure is EAGAIN at `open()`, it is not caused by our concurrency,
and it is episodic — one burst, then hours of nothing. **What is not:** which class of share event
produces it, and therefore whether any mount option short of `hard` would prevent it.

---

## 5. What this means for the three goals

| goal | verdict |
|---|---|
| Delete `READ_SEM`/`set_read_limit!`/`read_limit`/`__init__`/env var | **Done.** Measured to prevent nothing; cost ~5%. |
| Delete the retry loop | **Declined, on new grounds.** Not because it is constantly needed — it fired zero times in 101,790 reads — but because it is free when the share is healthy and is the only thing standing between an episode and an aborted run. |
| Stop blaming the user's data | **Done.** Failures now carry ffmpeg's own words. |

### On "I can't imagine this amount of failure"

That instinct was right, and the previous investigation's framing was wrong. There is no steady
drip of failures requiring a retry on 7% of stages. There are **long stretches — hours, hundreds of
thousands of reads, dozens of reconnects — with nothing whatsoever**, punctuated by rare episodes
that fail a third of everything in flight. The retry is invisible in the first regime and decisive
in the second.

The argument for keeping it is therefore not "the share is flaky and we must cope". It is: the loop
executes exactly one `read` per frame when nothing is wrong, so its cost in the normal case is
zero, and the alternative is that a rectification stage occasionally dies on a mount that
reconnects roughly five times an hour while nobody is touching it.

The argument for *deleting* it is real too, and it lives one layer down: fix the mount, and the
loop becomes provably dead code. That is worth doing, and it is the only version of "delete the
retry" that does not amount to hoping.

### Two adjacent exposures, neither of which I changed

**`Probing.probe_fields` has the same failure mode and no retry at all.** It opens the share 386
times per run across the two gateways (372 runs + 14 calibrations), each open as vulnerable as a
frame read's. A single EAGAIN there aborts the run. Its reporting is fixed — it now quotes ffprobe
instead of asserting corruption — but no retry was added, because adding a second workaround for a
mount problem is the wrong direction. Worth knowing that this stage is *less* protected than the
one everybody has been worrying about, not more.

**`PawsomeTracker.OPENVIDEO_LOCK` is load-bearing for a reason it does not claim.** It exists
because `VideoIO.openvideo` is not thread-safe, which is true and sufficient on its own. But it is
*also* the only thing making tracking's opens serial — one open at a time, ~0.6/s — and tracking is
the stage that reads a hundred times the bytes with no retry and has never been seen to fail. If a
future pass at candidate 06 flattens that lock away in the name of concurrency, tracking starts
issuing concurrent opens against this share, and there is no retry anywhere in that path to catch
what happens next. The lock should not be removed without measuring that, whatever the
thread-safety situation in VideoIO by then.

### The retry can only be deleted by fixing the mount

In rough order of expected value:

1. **Find out why `lces1133cs` reconnects.** ~1,000 session reconnects is the root cause and
   everything else is a workaround. `dmesg` is unreadable here (`kernel.dmesg_restrict = 1`), so
   this needs a root shell: `dmesg | grep -i 'CIFS: VFS:'` carries the reason (timeouts, credential
   renewal, server restarts). Correlate with server-side SMB logs.
2. **Remount `hard` and re-measure.** This is the change that would make the retry dead code. It
   trades a failure mode for a different one — `hard` blocks rather than erroring, which interacts
   badly with the credit stall documented in `CIFS-SHARE-INVESTIGATION.md` §4 — so it must be
   measured, not assumed. Requires root; could not be tested here.
3. **Revisit `actimeo=1`/`closetimeo=1`.** Both are unusually aggressive and force constant
   revalidation, which is pure metadata load on a server that is already unhappy.

Until one of those lands, deleting the retry means accepting that roughly one rectification stage
in fourteen aborts, and does so on a mount that reconnects while nobody is using it.


---

## 6. What was not established

- **Which class of share event destroys reads.** Reconnects are common and almost always harmless
  (§4.1); one episode was catastrophic. The distinguishing feature is unidentified.
- **Whether an established handle survives what an in-flight `open()` does not.** The `bare_open`
  vs `held_handle` arms were built to answer it and both sat at zero for want of an episode. This
  is the most likely explanation for tracking's immunity and it remains a hypothesis.
- **Whether `hard` would fix it.** It is the mechanism-level prediction of this report and it could
  not be tested: no passwordless root here, and the mount is not in `/etc/fstab`.
- **The true episode frequency.** Two data points — a bad afternoon (4 aborts in 58 iterations) and
  a good night (0 in 522) — do not make a rate.
- **Whether the corrupt file `C3. clear dense_trees dance/videos/20251125-0909.MP4` is still
  unreferenced.** It was in the previous investigation, and it is now distinguishable from a share
  failure by its message ("moov atom not found") and its exit code (183, not an errno), but nobody
  has decided what to do about it.

## 7. Reproducing this

Harness scripts live in the session scratchpad, not the repo. The essentials:

- **Capture what actually failed.** Never `read(cmd)` a diagnosis you intend to report. Drain
  stdout and stderr through `Pipe`s concurrently with the `wait`, and record `exitcode`,
  `termsignal` and both streams. Everything in §1 followed from doing this once.
- **Decode the exit code.** ffmpeg returns the negated errno, so exit = `256 − errno`. Verify the
  mapping on a file you `chmod 000` (EACCES → 243) before trusting it on the share.
- **Reconnect counters.** `grep -oE "[0-9]+ session [0-9]+ share reconnects" /proc/fs/cifs/Stats`,
  and `grep "Instance:" /proc/fs/cifs/DebugData` for the per-server counts — the file server is the
  one that matters and it is not the one in the mount path (`/proc/fs/cifs/dfscache` shows why).
- **Pair the arms in time.** Failures are episodic, so any two configurations measured in sequence
  are measuring different weather. Alternate them iteration by iteration, shuffled within the pair.
