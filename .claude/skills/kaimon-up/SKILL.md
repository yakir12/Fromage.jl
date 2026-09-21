---
name: kaimon-up
description: Bring up and health-check Kaimon for Fromage.jl — own Julia session, Revise, Qdrant index. Use before the first `ex`, `run_tests` or `search_code` of a session in this repo.
---

# Kaimon up (Fromage.jl)

Get a Julia session of your own and prove every Kaimon layer this repo leans on is live, so a
broken layer surfaces in the first minute rather than mid-task. CLAUDE.md §2's startup checklist
is the reference behind each step — why it exists, and what to do when it fails. This skill is
the sequence.

Skip it for work that touches no Julia and no code search (git, a docs-only edit).

## 1. Fan out

Issue these in **one message** — none depends on another:

- `ping()`
- `start_session(project_path="/home/yakir/Sync/evri/Fromage.jl", name="fromage")` — unless you
  already hold a key this conversation started; then reuse it, provided `ping` lists it as
  connected (start a fresh one if not).
- `grep_code(pattern="^# Every retry in this package", path="src")` — the access-prompt canary.
- `search_code(query="retry reading a video frame from the network share when it fails with EAGAIN", collection="fromage")`

Done when:

- `start_session` returned an 8-char key. "Process died" → CLAUDE.md §2 step 2 (read the log from
  the last `--- Session … starting` line; the known cause is KaimonGate missing from the new
  Julia's global environment).
- `grep_code` returned exactly `src/shareio.jl:1`, with no access prompt.
- `search_code` ranked `src/shareio.jl` (L1–50) and `DECISIONS.md` in its top five.

## 2. Check the environment

`investigate_environment(session=<key>)`. Done when it reads `Project: Fromage v…` at this repo's
path and `Revise: active`. Revise is loaded by the session itself; there is nothing to launch. A
different active project means `ex` is off-limits in that session — stop and tell the user.

## 3. Smoke eval

```
ex(e="using Revise, Fromage; (VERSION, pkgversion(Fromage), Threads.nthreads(), \"Fromage\" in [p.name for p in keys(Revise.pkgdatas)])",
   q=false, ses=<key>)
```

Done when it returns a tuple ending in `true` — Revise is tracking Fromage, so `src/` edits take
effect on the next eval. Pass `ses=<key>` on every session-bound call from here on.

## 4. Report

One short block: session key, Julia version, Fromage version, thread count, Revise tracking, and
one line each for the canary and the index. Name any step that did not meet its criterion, and
what it printed.

The Kaimon quiz is not part of this sequence; CLAUDE.md §2 step 0 says when to take it.
