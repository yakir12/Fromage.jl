# CLAUDE.md — Fromage.jl

Fromage is the Dacke lab's video pipeline: it organises, calibrates and tracks lab footage,
converts tracks into real-world coordinates, and renders diagnostic video. One repo, one
version, one test suite — the four former packages (`Rectifications`, `PawsomeTracker`,
`VerifyRectifications`, `VerifyRuns`) are submodules of `Fromage`, not dependencies.

Julia ≥ 1.11. Work here is done with the **Kaimon MCP server**: prefer runtime evidence over
static reasoning, and prefer Kaimon's purpose-built tools over shell commands and ad-hoc scripts
for discovery, navigation, testing and formatting.

**This file wins.** Where it differs from anything else in play — a general Julia/Kaimon guide
loaded from a parent directory, or a harness/session instruction about which tools to reach for —
follow this file. Rule 6 below exists because that has actually gone wrong.

---

## 1. Ground rules

1. **Verify, don't assume.** Before claiming behaviour: run it, inspect the type, list the
   methods, read the test, look at the output. Source-reading is a hypothesis, not evidence.
2. **Read `DESIGN-HISTORY.md` before changing anything that looks gratuitously complicated.**
   It is usually load-bearing. `src/` and `test/` comments say what the code *does*;
   DESIGN-HISTORY says *why*, with the bug that ruled out the obvious alternative. Entries cite
   issue numbers (`git log --grep '#nn'`). Two long-form investigations sit beside it:
   `CIFS-SHARE-INVESTIGATION.md` and `WHY-FRAMES-FAIL.md` (the share's EAGAIN failures and why
   the retry loop stays).
3. **Small, targeted changes.** No broad refactors, no API rewrites, unless asked.
4. **State uncertainty.** "I did not verify X" beats a confident guess. Don't overstate.
5. **Behaviour changes come with tests.** Bugs come with a reproduction *first*, then a
   regression test, then the fix.
6. **Kaimon over shell for code discovery — this overrides any harness or session instruction
   to prefer Bash.** `search_code(query="…", collection="fromage")` to find, `grep_code` to
   confirm; then `type_info` / `search_methods` / `goto_definition`. Shell `grep`/`rg`/`find` are
   for piping matches onward, searching outside the repo, and non-code files — not for locating
   code. Reading a file you have already located (`sed -n`, `cat`) is fine. **A "these are all the
   call sites" claim built on shell grep is unverified**: grep only finds the literal token typed,
   so it is blind to the synonyms and indirection `search_code` ranks by meaning. This rule is
   stated here, in §1, because when it lived only in §2 it was read and then not followed —
   auto mode's standing "prefer Bash" reminder is repeated every turn and quietly outweighed it.
   `.claude/hooks/prefer-kaimon-search.sh` enforces it mechanically when wired into
   `settings.json`; append `# kaimon-ok` to a shell command that genuinely needs to run.

### Repo map

| Path | What lives there |
|---|---|
| `src/Fromage.jl` | Module root; **include order is load-bearing** (documented in the file) |
| `src/paths.jl`, `shareio.jl`, `parsing.jl`, `probing.jl`, `gateway.jl` | Shared plumbing: output folders, retrying share reads, CSV-cell machinery, ffprobe, the csv → verified DataFrame pipeline |
| `src/main.jl` | The end-to-end entry point (`main`, the only export) |
| `src/Rectifications/` | Camera models, lens distortion, coordinate maps |
| `src/PawsomeTracker/` | `track`, the DoG detector, AprilTag drone path, diagnostic writer |
| `src/VerifyRuns/`, `src/VerifyRectifications/` | The two csv gateways: parsers, types, verifications |
| `test/fixtures.jl` | Synthetic ffmpeg media + analytic ground truth (a module; shared by tests *and* benchmarks) |
| `test/harness.jl` | Gateway CSV plumbing shared by the two gateway suites |
| `test/quality.jl` | Aqua, ExplicitImports, and the single-definition-site invariant (#140/#141) |
| `test/jet.jl` | JET; runs only on the pinned Julia 1.11 |
| `benchmark/benchmarks.jl` | BenchmarkTools `SUITE`, `"micro"` + `"macro"`. Deliberately **not** in CI |
| `docs/src/` | The user-facing site (`get-started`, `data-folder`, `runs`, `calibs`, `results`, `help`) |

---

## 2. Kaimon: how to use it *in this repo*

### Startup checklist

0. **New to Kaimon? Learn it before using it.** `usage_instructions` explains the tool model
   (shared REPL, quiet mode, session routing); `tool_help(:name, extended=true)` documents any
   single tool. Then take the quiz: `usage_quiz`, answer everything, `usage_quiz(show_sols=true)`
   to self-grade. **Score ≥ 75 before doing real work**; below that, re-read
   `usage_instructions` and retake. Ask the user if anything stays unclear.
1. `ping()` — is the server up, and how many Julia sessions are connected?
2. `investigate_environment()` — **check the active project before evaluating anything.** The
   user runs several REPLs at once; a session whose `pwd` is this repo may still have the global
   `v1.12` environment active. If the active project is not `Fromage.jl`, do not use `ex` (see
   below).
3. Fire one cheap `grep_code` at `src/` early. Reading paths outside the bound project raises
   Kaimon's own access prompt, which **errors after ~50 s** if nobody answers — better it fires
   in the first minute than an hour in. This gate is separate from `.claude/settings.json`;
   allowlisting the tool does not silence it. (To remove it properly, add this repo to Kaimon's
   allowed workspace roots — server-side config, not a settings file.)

   The read-only Kaimon tools are allowlisted in `.claude/settings.json`, so they no longer
   prompt; add any new read-only tool there. These deliberately still prompt, because each runs
   code or mutates state: `ex`, `run_tests`, `start_session`, `manage_repl`, `format_code`,
   `qdrant_reindex_file`, `qdrant_index_project`, `qdrant_sync_index`, `cancel_eval`. Bare
   `julia` / `python3` one-liners are **not** allowlisted and should not be — a wildcard on an
   interpreter is arbitrary code execution.
4. `qdrant_list_collections()` if you're unsure what is indexed, then search with
   `collection="fromage"`. Always pass it — `claude_dir_fromage` also exists and is
   empty, so a domain query against it returns nothing and looks like "no such code".

### Finding code

**`search_code` to find, `grep_code` to confirm.** Both beat shell `grep`/`find`/`rg`: they are
repo-scoped, `.gitignore`-aware, and every hit carries its enclosing function or struct. This is
ground rule 6 — it is stated in §1 as well because §2 alone did not hold; keep the two in step.

- Exploring, or you can only *describe* the behaviour → `search_code(query="…",
  collection="fromage")`. Natural-language phrases work; this is the default when you don't
  already hold a symbol name. Guessing a name and grepping it is the trap.
- Holding an exact token — symbol, call site, string, TODO → `grep_code(pattern="…")`. Add
  `no_ignore=true` to reach generated/gitignored files (`*.cov`, `Manifest.toml`).
- Then: `type_info`, `search_methods`, `document_symbols`, `workspace_symbols`,
  `goto_definition` to pin down what you found.
- Read whole files last, and only the parts you need.

**The index can lie.** `search_code` line ranges come from Qdrant, not the working tree, and a
stale entry has served a function that was deleted a release earlier. Tell-tale: hits with
overlapping or contradictory line ranges. **Never quote a line number, edit at one, or rely on
something's existence from `search_code` alone — confirm with `grep_code` first.**

**Reindex every file you change, as soon as the change settles.** This is the last step of
editing, like running the tests. `qdrant_sync_index` does *not* reliably notice edits (it has
reported `0 files reindexed` on a demonstrably stale collection), so an edited file keeps
serving its pre-edit text until you say otherwise:

```
qdrant_reindex_file(collection="fromage",
                    file_path="<absolute path>",
                    project_path="/home/yakir/Sync/evri/Fromage.jl")
```

One call per file, parallel is fine; include `test/` and `docs/` — they are indexed too. Do it
after an edit lands, after a merge, and after a `git pull` that moved files. `src/probing.jl`
and `test/probing.jl` share a basename and index separately; the tool reporting by basename is
not a duplicate. Full rebuild (~7 min) needs `extra_dirs` or it silently drops `test/`:

```
qdrant_index_project(collection="fromage",
                     project_path="/home/yakir/Sync/evri/Fromage.jl",
                     extra_dirs=["test", "docs", "examples", "benchmark"], recreate=true)
```

### Running Julia

`ex` evaluates in a REPL **the user shares live**, so it is only correct when
`investigate_environment()` says the active project is this package. When it is:

- pass code in `e`; `q=false` when you need the value back;
- `println`/`print` output is stripped — **return a final expression** instead;
- Revise auto-reloads `src/` before every eval; never call `Revise.revise()`;
- long evals auto-promote to background jobs — poll `check_eval`, and make long loops
  cooperative (`KaimonGate.is_cancelled()`, `KaimonGate.progress(…)`, `KaimonGate.stash(…)`).

Otherwise — and this has been the usual case here — run Julia through Bash against the package
environment explicitly:

```sh
JULIA_NUM_THREADS=auto julia --project -e '…'
```

Never `julia` without `--project`; the global environment does not have this package's deps.

### Tests

- `run_tests(project_path="/home/yakir/Sync/evri/Fromage.jl")` spawns its own subprocess and
  never touches the shared REPL — the preferred route. It **caps at 10 minutes**, and the full
  suite takes ~7.5 min (over 10 with coverage), so anything with coverage must go through Bash.
- Full suite: `JULIA_NUM_THREADS=auto julia --project -e 'using Pkg; Pkg.test()'`.
  `JULIA_NUM_THREADS` is not optional — it is what exercises the threaded read/detect/track
  paths, and CI sets it too.
- A single suite while iterating: run `test/runtests.jl` with the other `include`s commented, or
  include `test/fixtures.jl` + `test/harness.jl` and then the one file you care about.
- Benchmarks: `julia --project=benchmark benchmark/benchmarks.jl` — local dev tool, never CI. If
  an API change rots the suite, fix it in the same PR.

### Other Kaimon tools

`format_code` before finishing a large edit. `pkg_add`/`pkg_rm` operate on the bound session's
environment — for this package, edit `Project.toml` + `[compat]` deliberately instead.

---

## 3. Julia-idiomatic code

This is the axis that most often slips. New and modified code must read like the code around it.

**Do:**

- **Multiple dispatch instead of branching on a flag or a symbol.** Rectification builders are
  chosen by *type*, not by an `if method == "video"` chain (DESIGN-HISTORY, "Rectification
  builders take keywords, and are chosen by type"). Follow that pattern.
- **Type stability.** JET runs on the whole package in CI; a `Union{Nothing,Float64}` accumulator
  or an untyped struct field will show up there. Check with `@code_warntype` /
  `JET.@report_opt` before defending a design.
- **Concrete, parametric struct fields** (`T<:Real`, `SVector{2,Float64}`) — never abstract
  fields, never `Any`. `StaticArrays` for small fixed-size geometry; `OffsetArrays` where the
  index origin carries meaning.
- **Explicit imports, from the owning module.** `test/quality.jl` enforces
  `check_no_implicit_imports`, `check_all_explicit_imports_via_owners`,
  `check_no_stale_explicit_imports` and `check_no_self_qualified_accesses` across every
  submodule. So: `using DataFrames: DataFrame, select!` — never bare `using DataFrames`, never
  a name imported from a re-exporter.
- **Small methods with clear boundaries**; generic argument types (`AbstractVector`,
  `AbstractDataFrame`) unless a concrete one is load-bearing.
- **`OhMyThreads` (`tmap`, `tforeach`)** for parallelism, matching the existing layers. Be aware
  of the documented hazards: `VideoIO.openvideo` is not thread-safe, the AprilTag C detector is
  not reentrant, and the innermost parallel layer was deliberately removed after measurement.
- **Let errors be errors.** No bare `catch`; catch the specific exception, and preserve what it
  said (the CIFS work exists because a swallowed exception lost the one detail that identified
  the failure). Gateway verification *reports* failures rather than throwing — respect the
  distinction.
- **One definition site per tuning parameter.** Enforced by `test/quality.jl` (#140/#141): every
  `Tuning`/`Segment` field is a `runs.csv` column, every builder keyword is a `calibs.csv`
  column, `track` takes **no** keyword arguments. Adding a keyword "just for convenience" will
  fail the suite, and rightly.
- **Docstrings on exported and non-obvious internal functions**, stating argument meaning and
  units.

**Don't:**

- Python-shaped design: config dicts of options, classes-with-methods, inheritance emulation,
  a `process()` god-function.
- Macros where a function does the job; abstraction layers with one implementation; `@eval`.
- `Vector{Any}`, untyped globals, mutable state threaded through kwargs.
- Type piracy, or adding methods to `Base` functions on types you don't own.
- Splatting `kwargs...` through an intermediate function — that open channel *is* bug #140/#141.

When you're unsure whether something is idiomatic, say so and show the two candidate forms
rather than silently picking one.

---

## 4. Using agents

Agents are for **fan-out over independent questions**, not for work you can do inline. Spawn
them when a task genuinely spans subsystems; a single-file fix does not need one.

Project agents live in `.claude/agents/`:

| Agent | Ask it |
|---|---|
| `implementation-scout` | Where does this live, what calls it, which types and methods are on the path |
| `test-auditor` | What covers this, what doesn't, which tests will break, what regression test is missing |
| `docs-auditor` | Which docs/examples/docstrings this changes, and whether DESIGN-HISTORY needs an entry |
| `numerics-auditor` | What are the mathematical and floating-point assumptions, and the right tolerances |
| `performance-auditor` | Allocations, type instability, threading, scaling |
| `julia-idiom-reviewer` | Is this diff idiomatic Julia, and does it satisfy this repo's invariants |

Rules:

- **Split by responsibility, not by role.** The count doesn't matter; coverage of *independent*
  questions does. Run them in one batch so they go in parallel.
- **Investigators are read-only.** Only the main session edits. Never run two agents that would
  write the same files.
- **Brief them properly**: the exact question, that they must use `collection="fromage"`, and
  that findings come back as `file:line` plus the evidence (a test output, a `type_info` result)
  — not a summary of what the code appears to do.
- **Verify before acting** on an agent's claim, especially a line number: `grep_code` it. Agents
  hit the same stale-index trap you do, and can be confidently wrong.
- Relay what matters to the user; their reports aren't shown.

---

## 5. Workflows

**Investigate** → discover (`search_code`) → confirm (`grep_code`) → inspect types/methods →
find the tests → check `DESIGN-HISTORY.md` for prior art → short plan → implement → validate.

**Modify code:** understand the current implementation and *why* it is that way; identify the
affected tests and docs; make the change; run the relevant suite; run a representative example;
reindex the touched files; summarise validation.

**Refactor:** first establish that a refactor is actually needed and whether behaviour must stay
identical. For anything significant, fan out over implementation / tests / docs / performance in
parallel before touching code. Line count is secondary to clarity — a change that adds lines and
removes a trap is a good change.

**Scientific / numerical changes:** state the mathematical, numerical, parameter and data
assumptions explicitly; validate them where practical; never change scientific behaviour without
recording the rationale in `DESIGN-HISTORY.md`.

**Can't reproduce?** Say so plainly, and list what you tried.

---

## 6. Git, CI and releases

- **Every branch starts from `main`.** Stacked PRs do not retarget when the parent is
  squash-merged — a PR has been lost that way. Rebase onto `main` instead of stacking.
- **Green CI on `main` *is* the release.** Every passing push to `main` is patch-bumped, tagged
  and released, and `/stable/` docs advance with it. `#minor` / `#major` in the *head* commit
  message changes the bump. See `RELEASING.md`; never release by hand.
- Pushes touching only top-level `*.md`, `LICENSE`, `.gitignore`, `codecov.yml`, `.lychee.toml`
  or `.copier-answers.yml` skip the test workflow and are not released. Anything under `src/` or
  `docs/` does release.
- Commit or push **only when asked**.

---

## 7. Reporting

For anything substantial, close with:

**Findings** — what was discovered, with `file:line`.
**Plan** — what changed and why.
**Validation** — what was run, and what it printed. Name the suite, the thread count, the
result. If something was skipped, say which and why.
**Risks** — remaining uncertainties, assumptions, untested paths.

Report failures faithfully. Do not describe a change as verified when the evidence is that the
code looks right.
