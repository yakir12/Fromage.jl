# Why frame reads fail without the retry

**Date:** 2026-08-20 · **Package:** Fromage.jl at `cifs-root-cause` · **Context:** follow-up to
`CIFS-SHARE-INVESTIGATION.md`, which established *that* ~7% of rectification stages abort without
the retry loop but not *why*, and left "reproduce it and find the mechanism" as the open question.

**Short version.** The failure is `open()` returning **EAGAIN**, and it is now captured verbatim
rather than inferred. It is not caused by our concurrency: 5,371 reads swept across concurrency 1
to 48 produced **zero** failures, while a *completely idle* minute of the same mount produced the
highest reconnect rate measured. The limiter was therefore deleted. The retry, by contrast, is
load-bearing — but only because the mount is `soft`, which is the option that tells the kernel to
hand a reconnect to userspace as EAGAIN instead of reissuing the request itself. The retry is a
userspace reimplementation of what a `hard` mount does in the kernel, and that is the only way to
delete it honestly.

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
reconnect and surface as **-EAGAIN**. On a `hard` mount the kernel would reissue them itself and
the application would never see anything. So:

> **The retry loop in `_read_frame` is a userspace reimplementation of what `hard` does in the
> kernel.** It exists because the mount asked the application to do the retrying.

That also explains the shape of the failures — bursts across unrelated files, since one reconnect
kills everything open at that instant — and the 5–15 s hang before each one, which is the request
sitting in flight until the reconnect abandons it.

---

## 5. What this means for the three goals

| goal | verdict |
|---|---|
| Delete `READ_SEM`/`set_read_limit!`/`read_limit`/`__init__`/env var | **Done.** Measured to prevent nothing; cost ~5%. |
| Delete the retry loop | **Not from inside the application.** It covers reconnect windows on a `soft` mount. |
| Stop blaming the user's data | **Done.** Failures now carry ffmpeg's own words. |

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
