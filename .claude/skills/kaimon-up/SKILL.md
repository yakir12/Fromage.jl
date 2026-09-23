---
name: kaimon-up
description: Bring up and health-check Kaimon for Fromage.jl — own Julia session, Revise, Qdrant index. Use before the first `ex`, `run_tests` or `search_code` of a session in this repo.
---

# Kaimon up (Fromage.jl)

Get a Julia session of your own and prove every Kaimon layer this repo leans on is live, so a
broken layer surfaces in the first minute rather than mid-task. This skill is the single home for
bring-up and its troubleshooting; CLAUDE.md §2 only points here.

Skip it for work that touches no Julia and no code search (git, a docs-only edit).

## 0. Learn the tool model (once per session)

Read `usage_instructions` before the first Kaimon call that runs code; `tool_help(:name,
extended=true)` documents any single tool. When you have not worked with Kaimon before, or the
user asks, take `usage_quiz`, then `usage_quiz(show_sols=true)` to self-grade; below 75, re-read
and retake. **The quiz's model answer `stash(:completed, i)` is wrong** — `KaimonGate.stash` takes
a `String` key (CLAUDE.md §2, "Running Julia").

## 1. Fan out

Issue these in **one message** — none depends on another:

- `ping()`
- `start_session(project_path="/home/yakir/Sync/evri/Fromage.jl", name="fromage")` — unless you
  already hold a key this conversation started; then reuse it, provided `ping` lists it as
  connected (start a fresh one if not). "Session already running for this project" means Fromage's
  agent-spawned session is still up from an earlier conversation: use that key once step 2
  confirms its project. Never borrow another project's session.
- `grep_code(pattern="^# Every retry in this package", path="src")` — the access-prompt canary.
- `search_code(query="retry reading a video frame from the network share when it fails with EAGAIN", collection="fromage")`
- `qdrant_list_collections()`

Done when:

- `start_session` returned an 8-char key, new or already running. "Process died" → see
  **Troubleshooting** below.
- `grep_code` returned exactly `src/shareio.jl:1`, with no access prompt.
- `search_code` ranked `src/shareio.jl` (L1–50) in its top five. Agent docs that quote this
  query (this skill among them) can outrank it; that is expected, not a stale index.
- `qdrant_list_collections` lists `fromage` (vector counts show as `unknown`; that is normal).

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
effect on the next eval. Pass `ses=<key>` on every session-bound call from here on: the user
usually has other projects' sessions connected too.

## 4. Report

One short block: session key, Julia version, Fromage version, thread count, Revise tracking, and
one line each for the canary and the index. Name any step that did not meet its criterion, and
what it printed.

## Troubleshooting

**`start_session` → "Process died".** Read `~/.cache/kaimon/sessions/Fromage.jl.log` *from the last
`--- Session … starting` line* — the log is appended to across every session ever started, so the
first `ERROR` is usually old. The known cause is `KaimonGate failed to precompile … Package ZMQ …
is required but does not seem to be installed`: the spawned REPL loads `KaimonGate` from the
**global** environment of whatever Julia juliaup's `release` channel points at, and Fromage
deliberately does not depend on it. It recurs every time `release` moves to a new minor
(`juliaup status` shows it). Fix by installing it there — never into this package's `Project.toml`:

```sh
julia --project=@v1.NN --startup-file=no -e 'using Pkg; Pkg.add("KaimonGate")'
```

The codex project's session is no evidence either way: it lists KaimonGate as a direct dependency.

**The canary prompts for access.** Kaimon's own gate on paths outside the bound project errors
after ~50 s unanswered, and is separate from `.claude/settings.json`. The repo belongs under
`grep_paths` in `~/.config/kaimon/projects.json`; a prompt here means that config changed.

**`search_code` returns unrelated hits or nothing.** Check that `collection="fromage"` was passed —
without it the search falls back to the last-used session's project. If `src/shareio.jl:1` is not
`# Every retry in this package…`, the index is stale: rebuild it with the command in CLAUDE.md §2,
"Finding code".

**No session obtainable at all.** Run Julia through Bash against the package environment:
`JULIA_NUM_THREADS=auto julia --project -e '…'`. Never `julia` without `--project`.
