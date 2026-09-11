# CLAUDE.md — Fromage.jl

Fromage is the Dacke lab's video pipeline: it organises, calibrates and tracks lab footage,
converts tracks into real-world coordinates, and renders diagnostic video. One repo, one
version, one test suite — the four former packages (`Rectifications`, `PawsomeTracker`,
`VerifyRectifications`, `VerifyRuns`) are submodules of `Fromage`, not dependencies.

Julia ≥ 1.13. Work here is done with the **Kaimon MCP server**: prefer runtime evidence over
static reasoning, and prefer Kaimon's purpose-built tools over shell commands and ad-hoc scripts
for discovery, navigation, testing and formatting.

**This file wins.** Where it differs from anything else in play — a general Julia/Kaimon guide
loaded from a parent directory, or a harness/session instruction about which tools to reach for —
follow this file. Rule 6 below exists because that has actually gone wrong.

---

## 1. Ground rules

1. **Verify, don't assume.** Before claiming behaviour: run it, inspect the type, list the
   methods, read the test, look at the output. Source-reading is a hypothesis, not evidence.
2. **Three files, three trigger conditions. Two of them are not optional.**
   - **`CONTEXT.md` — read it before *naming* anything**, and before proposing that a term is
     ambiguous. It is the domain model: what a run, segment, track, session, rectification,
     calibration, frame and space are, the seven coordinate spaces and their axis orders, and the
     rules that decide a name. Most terminology questions are already answered there, including
     which words were deliberately left alone.
   - **`DECISIONS.md` — read it before *removing* anything**, or anything that looks gratuitously
     complicated. It is usually load-bearing: it records what was tried, measured and not kept, so
     you do not re-add a parallel layer that was benchmarked away. Entries cite issue numbers
     (`git log --grep '#nn'`).
   - `src/` and `test/` comments say what the code *does*. That is the default home for mechanism —
     if a fact has a line of code to sit beside, it belongs there, not in either file above.

   Two long-form investigations sit beside them: `CIFS-SHARE-INVESTIGATION.md` and
   `WHY-FRAMES-FAIL.md` (the share's EAGAIN failures and why the retry loop stays).
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
| `CONTEXT.md` | The domain model: what the words mean, the coordinate spaces, the naming rules |
| `DECISIONS.md` | What was tried, measured and **not kept**, plus hazards with no code to sit beside |
| `src/Fromage.jl` | Module root; **include order is load-bearing** (documented in the file) |
| `src/paths.jl`, `shareio.jl`, `parsing.jl`, `probing.jl`, `gateway.jl` | Shared plumbing: output folders, retrying share reads, CSV-cell machinery, ffprobe, the csv → verified DataFrame pipeline |
| `src/main.jl` | The end-to-end entry point (`main`, the only export) |
| `src/Rectifications/` | Camera models, lens distortion, coordinate maps |
| `src/PawsomeTracker/` | `track`, the DoG detector, AprilTag drone path, diagnostic writer |
| `src/VerifyRuns/`, `src/VerifyRectifications/` | The two csv gateways: parsers, types, verifications |
| `test/fixtures.jl` | Synthetic ffmpeg media + analytic ground truth (a module; shared by tests *and* benchmarks) |
| `test/harness.jl` | Gateway CSV plumbing shared by the two gateway suites |
| `test/quality.jl` | Aqua, ExplicitImports, the single-definition-site invariant (#140/#141) and the offline invariant (#159) |
| `test/persistent_tasks.jl` | Aqua's persistent-task check — the one network-dependent check, run by its own non-gating workflow (#159) |
| `test/jet.jl` | JET; gated on an allowlist of Julia minors (`JET_MINORS` in `runtests.jl`, currently 1.13) |
| `benchmark/benchmarks.jl` | BenchmarkTools `SUITE`, `"micro"` + `"macro"`. Deliberately **not** in CI |
| `docs/src/` | The user-facing site (`get-started`, `data-folder`, `runs`, `rectifications`, `results`, `help`) |

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
not a duplicate. A full rebuild takes several minutes — long enough to be worth avoiding when a
per-file reindex would do — and needs `extra_dirs` or it silently drops `test/`:

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
  never touches the shared REPL — the preferred route. It **caps at 10 minutes**. The full suite
  runs close enough under that cap to be at its mercy on a loaded machine, and a coverage run is
  reliably over it, so anything with coverage must go through Bash.
- Full suite: `JULIA_NUM_THREADS=auto julia --project -e 'using Pkg; Pkg.test()'`.
  `JULIA_NUM_THREADS` is not optional — it is what exercises the threaded read/detect/track
  paths, and CI sets it too.
- The suite needs no network once the deps are installed, and `test/quality.jl` asserts that it
  stays that way (#159). The one check whose result depends on it — Aqua's persistent-task check —
  is not in `runtests.jl`: run `julia --project=test test/persistent_tasks.jl`, which is what the
  `PersistentTasks` workflow does. That workflow is **not** gating, on the same terms as `Lint`, so
  a red one blocks no release and has to be read rather than waited on.
- A single suite while iterating: run `test/runtests.jl` with the other `include`s commented, or
  include `test/fixtures.jl` + `test/harness.jl` and then the one file you care about.
- The gateway helper `check` in `test/harness.jl` returns the **built objects** for a clean file — a
  `Vector{Run}`, not a DataFrame. Assertions written against the DataFrame it does not return look
  plausible and fail for the wrong reason.
- Benchmarks: `julia --project=benchmark benchmark/benchmarks.jl` — local dev tool, never CI. If
  an API change rots the suite, fix it in the same PR. **Read the allocation counts, not the
  clock** — see DECISIONS, "Wall-clock benchmarks on this machine are noise".

### Formatting

**Runic is the formatter (#238), and it is not `format_code`.** Runic has no configuration and no
line-length rule, which is why it was chosen (DECISIONS, "Runic is the formatter, and its check
does not gate"). It lives in its own shared environment and is deliberately absent from both the
package's and the test environment's dependencies, so install it once:

```sh
julia --project=@runic --startup-file=no -e 'using Pkg; Pkg.add(name = "Runic", version = "1")'
```

Then, from the repo root — format in place, or check without writing:

```sh
git ls-files -z -- '*.jl' | xargs -0 --no-run-if-empty \
  julia --project=@runic --startup-file=no -e 'using Runic; exit(Runic.main(ARGS))' -- --inplace
```

Swap `--inplace` for `--check --diff --verbose` to see the drift instead of fixing it; that is
exactly what `.github/workflows/Format.yml` runs, and it exits non-zero when anything differs.
`--verbose` earns its place: Runic's diff headers carry the basename alone, and this repo has four
`types.jl` and two `probing.jl`. The `Format` workflow is **not gating**, on the same terms as
`Lint` — read it, don't wait on it.

### Other Kaimon tools

`pkg_add`/`pkg_rm` operate on the bound session's environment — for this package, edit
`Project.toml` + `[compat]` deliberately instead.

---

## 3. Julia-idiomatic code

This is the axis that most often slips. New and modified code must read like the code around it.

**Do:**

- **Multiple dispatch instead of branching on a flag or a symbol.** Rectification builders are
  chosen by *type*, not by an `if method == "checkerboard"` chain (DECISIONS, "Rectification
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
- **One definition site per tracking or rectification parameter.** Enforced by `test/quality.jl`
  (#140/#141): every `Tuning`/`Segment` field is a `runs.csv` column, every builder keyword is a
  `rectifications.csv` column, `track` takes **no** keyword arguments. Adding a keyword "just for
  convenience" will fail the suite, and rightly.
- **Docstrings on exported and non-obvious internal functions**, stating argument meaning and
  units.
- **Mind the include order when you add a type annotation.** Method signatures are evaluated at
  *definition* time, so naming a type in one requires that type to already exist when the `include`
  defining the method runs. That is why `types.jl` is included first inside both gateways and
  `PawsomeTracker`, and why `src/Fromage.jl`'s own include order is load-bearing. Annotating an
  argument can therefore fail at load with a bare `UndefVarError` that says nothing about ordering.

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
| `docs-auditor` | Which docs/examples/docstrings this changes, and whether DECISIONS needs an entry |
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
find the tests → check `DECISIONS.md` for prior art → short plan → implement → validate.

**Modify code:** understand the current implementation and *why* it is that way; identify the
affected tests and docs; make the change; run the relevant suite; run a representative example;
reindex the touched files; summarise validation. That is the *investigation* half — deliver the
result through §6's workflow (branch → PR → validate ∥ CI → merge → post-merge → cleanup), which
is where a change is actually finished.

**Refactor:** first establish that a refactor is actually needed and whether behaviour must stay
identical. For anything significant, fan out over implementation / tests / docs / performance in
parallel before touching code. Line count is secondary to clarity — a change that adds lines and
removes a trap is a good change.

**Scientific / numerical changes:** state the mathematical, numerical, parameter and data
assumptions explicitly; validate them where practical; never change scientific behaviour without
recording the rationale in `DECISIONS.md`.

**Can't reproduce?** Say so plainly, and list what you tried.

---

## 6. Git, CI and releases

### The standard workflow for a fix

Follow this for every code fix, bug fix, refactor or other code change, unless told otherwise.

**A request to implement a fix authorizes the whole sequence** — branch, commit, push, open the PR,
merge, clean up — without asking again at each step. Absent such a request, do not commit or push.
Two points are hard approval gates (steps 7 and 10): a failure there is evidence that the plan was
wrong, and pushing through it is how a bad change lands anyway.

**One fix, one branch, one PR.** Never combine unrelated fixes into a branch or PR. Never stack:
a PR does not retarget when its parent is squash-merged, and one has been lost that way — every
branch starts from `main`, and if `main` has moved, rebase onto it rather than stacking.

1. **Branch.** `git checkout main && git pull`, then a new branch off it, named for the fix.
2. **Implement, test-first.** Only what the fix needs, plus what implementing it turns up as
   directly related. Build it in red-green slices at the seams the plan agreed — for a bug that
   is §1.5's order (reproduction, regression test, fix), and `/implement` drives
   `/mattpocock-skills:tdd` over it. Iterate against a single suite (§2), not the whole one.
3. **Start CI, then validate locally and review the diff.** Push the branch and open the PR
   *first*, before running anything locally. PR CI takes about 17 minutes and the local suite
   about 6½, and they check overlapping things independently — run them in series and the local
   time is spent twice. Nothing merges until both are green (step 8), so starting CI early risks
   only runner minutes on a branch that may still fail locally, and runner minutes are the cheap
   resource here; your wall clock is not. The threaded full suite is the gate:
   `JULIA_NUM_THREADS=auto julia --project -e 'using Pkg; Pkg.test()'`. Budget most of ten
   minutes. Kaimon's `run_tests` caps at 10 minutes, so a coverage run must go through Bash.
   The pass count is in the low thousands and climbs with almost every release, so it is only
   ever meaningful **as a before/after pair within one session**: note what `main` reports before
   you start, and compare after. A count that went *down* means a test stopped running — the
   number itself is not a target and is not worth recording here, because a figure pinned to a
   version is stale by the next one. Also run Runic over the tracked sources (§2, "Formatting")
   after a large edit, and reindex every file you changed (§2). **JET runs on an allowlist of
   Julia minors — `JET_MINORS` in `test/runtests.jl`, currently `(13,)`, the same minor
   `Test.yml` pins** — so a local run on
   1.13 includes it and a run on anything else does not. In CI it additionally runs on the ubuntu
   leg only (`FROMAGE_RUN_STATIC`); locally it defaults on, so **your run is the one that sees
   JET on macOS or Windows** — CI no longer will (DECISIONS, "JET runs once, on ubuntu"). That gap used to be silent and is not
   any more: an off-allowlist run warns and reports a `JET (SKIPPED — …)` testset, because the
   allowlist once said `(11, 12)` while the matrix said `"1"`, and when `"1"` rolled to 1.13 the
   analysis vanished from CI with everything still green. Read the summary, not just the exit
   code. Worth the care, because JET has rejected a design the whole
   suite accepted (DECISIONS, "The tracking functions take typed objects, and the two paths take
   different ones" — #202's `apriltag_guess` union split). `test/jet.jl`'s header explains why
   the gate is an allowlist and what adding a minor to it requires.
   A green suite is not the whole gate: **review the diff before it leaves the branch** —
   `/mattpocock-skills:code-review` (Standards + Spec), plus the `julia-idiom-reviewer` subagent
   (§4), which is the axis that most often slips and the one that knows this repo's structural
   invariants. Name the review skill in full: a bare `/code-review` resolves to the built-in
   review skill instead. Fan out to the other §4 auditors when the change earns them.
4. **Fix what fails, without asking.** Iterate until the suite is green, or until you cannot make
   confident progress. Only the second case is worth interrupting the user for.
5. **Write the PR description** — the PR itself went up at the start of step 3, so this is the
   point where it stops being a placeholder. State the problem, the solution, and the tradeoffs
   or limitations. Report the actual line delta against the estimate honestly: extracting shared
   code costs lines here, deleting a structure saves them.
6. **Watch the PR's CI** — by polling `gh pr checks <n>` in a loop, *not* with `--watch` (see the
   `gh` notes below). Poll on the **exit code**, not on the table: 8 means checks are still pending,
   0 that every one passed. **`TestOnPRs` triggers only on `src/**`, `test/**`, `*.toml` and
   `.github/workflows/**`**, and **`Format` only on `**.jl`** —
   so a docs-only or top-level-`*.md` PR legitimately has no *`TestOnPRs`* run, while a PR touching
   only `docs/make.jl` gets `Format`, `Lint` and `Docs` (all three match `docs/**`) but still no
   `TestOnPRs`. Absent checks there is expected, not something to wait on.
   Watch what the *merge* triggers separately, and on the right ref: an `AutoRelease` tag build
   (`Docs` on `v0.x.y`) does not appear in `gh run list --branch main`, so a watcher scoped to
   `main` reports the chain complete while the tag's docs build is still running.
7. **A red PR CI is an approval gate.** Investigate the root cause, determine the fix, explain the
   reasoning — and **ask before changing anything to make CI pass.**
8. **Merge only after every required check has passed.**
9. **Watch what the merge triggers.** The task is not done at merge. The chain is
   `push to main → Test (full matrix) → AutoRelease (bump, tag, GitHub release) → Docs on the new
   tag → /stable/ advances`. Expect **about 12 minutes** — ~9 for the matrix, seconds for
   AutoRelease, ~3 for the tag's docs build (measured 2026-09-11; RELEASING.md carries the table
   and the caveats, and these drift). **It is not queue time** — median wait from job created to
   job started was 3–5 seconds on every platform — and macOS is not reliably the long pole; the
   three legs now land within ~80 s of each other. A run that takes *far* longer is usually a cold
   depot cache, which doubles the matrix. `Lint` and `Format` are deliberately *not*
   gating, so neither a dead link nor a misplaced space can block a release.
10. **A red post-merge workflow is an approval gate**, on the same terms as step 7.
11. **Clean up.** `git checkout main && git pull` — the bot's bump commit leaves local `main` one
    behind after every release, and the pull brings the new tag too — then delete the **local** fix
    branch. Only the local one: the repository deletes merged branches on the remote by itself, so
    `git push origin --delete <branch>` just fails with "remote ref does not exist". Don't run it.

**Done means all of it:** local validation green, PR CI green, merged, post-merge automation green,
the release and version bump actually completed, cleanup done, and no remaining failure
attributable to the fix. Code written, local tests passing, a PR open, or even a PR merged — none
of those is "done" on its own, and none of them should be reported as done.

### Facts the workflow depends on

- **Green CI on `main` *is* the release.** Every passing push to `main` is patch-bumped, tagged
  and released, and `/stable/` docs advance with it. The *head* commit message controls the bump.
  See `RELEASING.md`; never release by hand, and never edit `version` in `Project.toml` — the bot
  owns it.
- **Never let a skip-CI or version-bump token appear in a commit message or PR body**, even when
  writing *about* them — GitHub honours them from the body, and a push that silently ran no
  workflows has already happened once. Paraphrase instead ("the skip-CI token"); `RELEASING.md`
  has the detail.
- **What does and does not release** — `Test.yml`'s `paths-ignore` is the single source of truth,
  because `AutoRelease` triggers on `Test` completing, so anything `Test` skips is never released.
  It ignores top-level `*.md` (`*` does not cross `/`, so `docs/src/*.md` still counts), `LICENSE`,
  `.gitignore`, `codecov.yml`, `.lychee.toml`, `.copier-answers.yml`, **`docs/agents/**`** and
  **`.claude/**`**. Everything else under `src/` or `docs/` does release — so batch a `docs/src/`
  correction into the PR that needs it, or it costs a second version bump.
  The last two are easy to get wrong in the direction that *costs* you nothing and *tells* you
  something false: `docs/agents/**` and `.claude/**` look like they release because they sit under
  `docs/` and look like config, and they do not — neither is loaded by the package or built into the
  site, so there is no `/stable/` for a tag to advance. `Docs.yml` carves `docs/agents/**` out with
  a negated pattern for the same reason, so a PR touching only those paths legitimately gets **no
  `Docs`, no `TestOnPRs` and no `Format`** — `Lint` alone, which matches `**/*.md`.
- **`gh` here is 2.100.0 (released 2026-09-03), upgraded from 2.23.0 on 2026-09-11.** Every
  limitation this file used to record is gone. What follows was *retested* on the new version, not
  assumed: `gh issue view <n>` and `gh pr edit` both used to die with a Projects-classic GraphQL
  error (`repository.issue.projectCards`) — and `gh pr edit` **printed that error while silently
  changing nothing**, which is how a PR description once stayed a placeholder after an edit that
  looked like it had failed loudly and harmlessly. Both work now. So do `gh pr checks --json` and
  `gh release list --json`, which 2.23.0 did not have. `gh api`, `gh run list --json` and
  `gh release view --json` still work. **If a `gh` call fails now, it is a real failure — do not
  reach for `gh api` as a version workaround.**
- **`gh pr checks` exits 8 while any check is still pending**, 0 when all have passed, 1 when one
  failed; `--json` carries a `bucket` field sorting each check into `pass`/`fail`/`pending`/
  `skipping`/`cancel`. That pair is the polling primitive to build a watcher on — an exit-code test
  beats counting rows out of the human-readable table.
- **Do not follow a PR with `gh pr checks <n> --watch` from here** — diagnosed on 2.23.0 and
  deliberately **not** retested on 2.100.0, because retesting needs a PR with genuinely pending
  checks and manufacturing one means a push that cuts a release. On the old version it drew a
  redrawing terminal display, so with stdout redirected — which is what a backgrounded tool call
  does — it emitted **zero bytes** across ten minutes of genuinely pending checks, and a silent
  watcher is indistinguishable from a hung one. (It was fine typed at a real terminal, and fine
  when every check had already settled, which is why it could look like it works.) Whether 2.100.0
  fixed it does not matter: polling on exit code 8 is visible, cheap and already correct. Poll
  `gh pr checks <n>` in a loop and print each check as it settles, so progress is visible and a
  broken query is too. Same rule for the post-merge chain with `gh run list`.
- When polling `gh` in a loop, run the query once on its own first. The original reason was a
  missing flag on 2.23.0, which no longer applies, but the failure shape outlives it: **any** query
  that breaks behind `2>/dev/null` becomes a watcher that polls forever and says nothing, which is
  hard to tell from a slow CI run. A first-iteration heartbeat line makes that distinction visible
  if you would rather not pre-check. Give the loop an explicit failure branch too: a filter that
  only matches success is silent through a crash, which reads exactly like "still running".

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

---

## 8. Agent skills

Configuration the installed engineering skills read. Distinct from §4, which is about subagents.

### Issue tracker

GitHub issues on `yakir12/Fromage.jl`, via the `gh` CLI (2.100.0 — every `--json` flag the skills
use works; see §6's `gh` notes). See `docs/agents/issue-tracker.md`. Delivering the work still
follows §6, not a skill's generic git workflow.

### Triage labels

The five canonical roles, each label string equal to its name, and all five exist on the repo —
`/triage` only ever *applies* labels, so a missing one would surface as a failed `gh issue edit`.
See `docs/agents/triage-labels.md`, which carries the table and the commands that created them.

### Domain docs

Single-context: `CONTEXT.md` at the root, with `DECISIONS.md` standing in for `docs/adr/`. See
`docs/agents/domain.md`.
