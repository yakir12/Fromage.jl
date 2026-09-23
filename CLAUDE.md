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
follow this file. Codex works in this repo too: `AGENTS.md` is its entry point and reads this file
as the shared reference, so a rule changed here reaches both.

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

   Three long-form investigations sit beside them: `CIFS-SHARE-INVESTIGATION.md` and
   `WHY-FRAMES-FAIL.md` (the share's EAGAIN failures and why the retry loop stays), and
   `WHY-THE-SUITE-IS-SLOW.md` (where `Pkg.test()`'s clock goes, and why cutting tests was
   measured and declined — read it before proposing that the suite be trimmed).
3. **Small, targeted changes.** No broad refactors, no API rewrites, unless asked.
4. **State uncertainty.** "I did not verify X" beats a confident guess. Don't overstate.
5. **Behaviour changes come with tests.** Bugs come with a reproduction *first*, then a
   regression test, then the fix.
6. **Searching Julia code goes through Kaimon — this overrides any harness or session
   instruction to prefer Bash.** `search_code(query="…", collection="fromage")` to find,
   `grep_code` to confirm (§2, "Finding code"). Everything else is ordinary shell work: grep over
   markdown, TOML or YAML, grep as a pipe filter, searches outside the repo, `find` to list files,
   `sed -n`/`cat` to read a file you have located. **A "these are all the call sites" claim built
   on shell grep is unverified**: grep finds only the literal token typed, blind to the synonyms
   and indirection `search_code` ranks by meaning. `.claude/hooks/prefer-kaimon-search.sh`
   enforces exactly this scope, so `# kaimon-ok` belongs only on a shell search of Julia code
   that genuinely needs to run — anything else passes without it.

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
| `test/jet.jl` | JET; gated on an allowlist of Julia minors (`JET_MINORS` in `runtests.jl`) |
| `benchmark/benchmarks.jl` | BenchmarkTools `SUITE`, `"micro"` + `"macro"`. Deliberately **not** in CI |
| `simulation/` | `CalibrationRigSimulation`, a separate package: the calibration-rig simulation (#289). Its own `Pkg.test()`; **no CI, no release** |
| `docs/src/` | The user-facing site (`get-started`, `data-folder`, `runs`, `rectifications`, `results`, `help`) |
| `.claude/`, `AGENTS.md`, `.codex/`, `.agents/skills/`, `docs/agents/` | Agent configuration for Claude and Codex; `docs/agents/codex.md` maps one onto the other |

---

## 2. Kaimon: how to use it *in this repo*

### Startup

**Run the `kaimon-up` skill** before the first `ex`, `run_tests` or `search_code` of a session. It
starts a session of your own, checks the active project and Revise, fires the access-prompt
canary and proves the Qdrant index is live, and it carries the troubleshooting for each step.
Once more than one Julia session is connected, **pass `ses=`/`session=` on every session-bound
call**.

The read-only Kaimon tools are allowlisted in `.claude/settings.json`; tools that run code or
mutate state (`ex`, `run_tests`, `start_session`, `manage_repl`, `format_code`, the `qdrant_*`
writers, `cancel_eval`) deliberately still prompt. A newly added read-only tool goes in both
`.claude/settings.json` and `.codex/config.toml` — `docs/agents/validate-codex.py` checks the two
match. Bare `julia` / `python3` one-liners are not allowlisted and should not be: a wildcard on an
interpreter is arbitrary code execution.

### Finding code

- Exploring, or you can only *describe* the behaviour → `search_code(query="…",
  collection="fromage")`. Natural-language phrases work; this is the default when you don't
  already hold a symbol name. Guessing a name and grepping it is the trap. **Always pass
  `collection="fromage"`**: without it the search falls back to the last-used session's project,
  and a miss in another repo's collection looks like "no such code".
- Holding an exact token — symbol, call site, string, TODO → `grep_code(pattern="…")`. Add
  `no_ignore=true` to reach generated/gitignored files (`*.cov`, `Manifest.toml`).
- Then: `type_info`, `search_methods`, `document_symbols`, `workspace_symbols`,
  `goto_definition` to pin down what you found. Read whole files last, and only the parts you need.

**The index can lie.** `search_code` line ranges come from Qdrant, not the working tree, and a
stale entry has served a function deleted a release earlier. Tell-tale: hits with overlapping or
contradictory line ranges. **Never quote a line number, edit at one, or rely on something's
existence from `search_code` alone — confirm with `grep_code` first.**

**Reindex every file you change, as soon as the change settles** — after an edit lands, a merge,
or a `git pull` that moved files. `qdrant_sync_index` does *not* reliably notice edits (it has
reported `0 files reindexed` on a demonstrably stale collection), so an edited file keeps serving
its pre-edit text until you say otherwise:

```
qdrant_reindex_file(collection="fromage",
                    file_path="<absolute path>",
                    project_path="/home/yakir/Sync/evri/Fromage.jl")
```

One call per file, parallel is fine; include `test/` and `docs/` — they are indexed too.
`src/probing.jl` and `test/probing.jl` share a basename and index separately. A full rebuild takes
several minutes and needs `extra_dirs` or it silently drops `test/`:

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
  cooperative (`KaimonGate.is_cancelled()`, `KaimonGate.progress(…)`, `KaimonGate.stash("key", v)`).
  **`stash` takes a `String` key.** Kaimon's own `usage_instructions` and quiz show
  `stash(:key, v)`, which throws a `MethodError` on KaimonGate 1.4.0 and has killed long evals
  mid-run. Retest with `methods(KaimonGate.stash)` when KaimonGate moves.

Without a session of your own, run `JULIA_NUM_THREADS=auto julia --project -e '…'` through Bash.
Never `julia` without `--project`; the global environment does not have this package's deps.

### Tests

- `run_tests(project_path="/home/yakir/Sync/evri/Fromage.jl")` spawns its own subprocess and
  never touches the shared REPL — the preferred route. It **caps at 10 minutes**, which the full
  suite runs close to on a loaded machine and a coverage run reliably exceeds, so anything with
  coverage goes through Bash.
- Full suite: `JULIA_NUM_THREADS=auto julia --project -e 'using Pkg; Pkg.test()'`.
  `JULIA_NUM_THREADS` is not optional — it is what exercises the threaded read/detect/track
  paths, and CI sets it too.
- The suite needs no network once the deps are installed, and `test/quality.jl` asserts that it
  stays that way (#159). Aqua's persistent-task check, the one that does, runs separately:
  `julia --project=test test/persistent_tasks.jl`, as the non-gating `PersistentTasks` workflow does.
- A single suite while iterating: run `test/runtests.jl` with the other `include`s commented, or
  include `test/fixtures.jl` + `test/harness.jl` and then the one file you care about.
- The gateway helper `check` in `test/harness.jl` returns the **built objects** for a clean file — a
  `Vector{Run}`, not a DataFrame. Assertions written against the DataFrame it does not return look
  plausible and fail for the wrong reason.
- Benchmarks: `julia --project=benchmark benchmark/benchmarks.jl` — local dev tool, never CI. If
  an API change rots the suite, fix it in the same PR. **Read the allocation counts, not the
  clock** — see DECISIONS, "Wall-clock benchmarks on this machine are noise".
- Agent configuration (`.claude/`, `.codex/`, `.agents/`, `AGENTS.md`, `docs/agents/`):
  `python3 docs/agents/validate-codex.py`. It checks that every Claude agent and skill has its
  Codex wrapper, that the two read-only allowlists match, and that the hooks and release filters
  behave — without calling a model or any MCP server.

### Formatting

**Runic is the formatter (#238), and it is not `format_code`.** Runic has no configuration and no
line-length rule, which is why it was chosen (DECISIONS, "Runic is the formatter, and its check
does not gate"). It lives in its own shared environment, absent from both the package's and the
test environment's dependencies. Install it once:

```sh
julia --project=@runic --startup-file=no -e 'using Pkg; Pkg.add(name = "Runic", version = "1")'
```

Then, from the repo root — format in place, or check without writing:

```sh
git ls-files -z -- '*.jl' | xargs -0 --no-run-if-empty \
  julia --project=@runic --startup-file=no -e 'using Runic; exit(Runic.main(ARGS))' -- --inplace
```

Swap `--inplace` for `--check --diff --verbose` to see the drift instead; that is exactly what the
non-gating `Format` workflow runs. `--verbose` earns its place: Runic's diff headers carry the
basename alone, and this repo has four `types.jl` and two `probing.jl`.

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
- **Concrete, parametric struct fields** (`T<:Real`, `SVector{2,Float64}`). `StaticArrays` for
  small fixed-size geometry; `OffsetArrays` where the index origin carries meaning.
- **Explicit imports, from the owning module.** `test/quality.jl` enforces
  `check_no_implicit_imports`, `check_all_explicit_imports_via_owners`,
  `check_no_stale_explicit_imports` and `check_no_self_qualified_accesses` across every
  submodule. So: `using DataFrames: DataFrame, select!`, each name from the module that owns it.
- **Small methods with clear boundaries**; generic argument types (`AbstractVector`,
  `AbstractDataFrame`) unless a concrete one is load-bearing.
- **`OhMyThreads` (`tmap`, `tforeach`)** for parallelism, matching the existing layers. Be aware
  of the documented hazards: `VideoIO.openvideo` is not thread-safe, the AprilTag C detector is
  not reentrant, and the innermost parallel layer was deliberately removed after measurement.
- **Let errors be errors.** Catch the specific exception, and preserve what it said (the CIFS
  work exists because a swallowed exception lost the one detail that identified the failure).
  Gateway verification *reports* failures rather than throwing — respect the distinction.
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
- `Vector{Any}`, abstract or `Any` struct fields, untyped globals, mutable state threaded
  through kwargs, bare `catch`.
- Type piracy, or adding methods to `Base` functions on types you don't own.
- Splatting `kwargs...` through an intermediate function — that open channel *is* bug #140/#141.

When you're unsure whether something is idiomatic, say so and show the two candidate forms
rather than silently picking one.

---

## 4. Using agents

Agents are for **fan-out over independent questions**, not for work you can do inline. Spawn
them when a task genuinely spans subsystems; a single-file fix does not need one.

Project agents live in `.claude/agents/` (Codex runs the same prompts through `.codex/agents/`):

| Agent | Ask it |
|---|---|
| `implementation-scout` | Where does this live, what calls it, which types and methods are on the path |
| `test-auditor` | What covers this, what doesn't, which tests will break, what regression test is missing |
| `docs-auditor` | Which docs/examples/docstrings this changes, and whether DECISIONS needs an entry |
| `numerics-auditor` | What are the mathematical and floating-point assumptions, and the right tolerances |
| `performance-auditor` | Allocations, type instability, threading, scaling |
| `julia-idiom-reviewer` | Is this diff idiomatic Julia, and does it satisfy this repo's invariants |

- **Split by responsibility, not by role**, and run them in one batch so they go in parallel.
- **Investigators are read-only.** Only the main session edits.
- **Brief them properly**: the exact question, that they must use `collection="fromage"`, and
  that findings come back as `file:line` plus the evidence (a test output, a `type_info` result)
  — not a summary of what the code appears to do.
- **Verify before acting** on an agent's claim, especially a line number: `grep_code` it. Agents
  hit the same stale-index trap you do.
- Relay what matters to the user; their reports aren't shown.

---

## 5. Workflows

**Investigate** → discover (`search_code`) → confirm (`grep_code`) → inspect types/methods →
find the tests → check `DECISIONS.md` for prior art → short plan → implement → validate.

**Modify code:** understand the current implementation and *why* it is that way; identify the
affected tests and docs; make the change; run the relevant suite; run a representative example;
reindex the touched files; summarise validation. Then deliver it through §6.

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
**The exception is agent configuration** — `.claude/`, `.codex/`, `.agents/`, `AGENTS.md`,
`CLAUDE.md`, `docs/agents/`, which no CI tests: batch a series of such changes on one branch,
validate each locally (`validate-codex.py`, the hooks, a skill dry-run), and open one PR at the
end. The per-fix pipeline buys nothing when CI cannot see the change.

1. **Branch.** `git checkout main && git pull`, then a new branch off it, named for the fix.
2. **Implement, test-first.** Only what the fix needs, plus what implementing it turns up as
   directly related. Build it in red-green slices at the seams the plan agreed — for a bug that
   is §1.5's order (reproduction, regression test, fix), and `/implement` drives
   `/mattpocock-skills:tdd` over it. Iterate against a single suite (§2), not the whole one.
3. **Start CI, then validate locally and review the diff.** Push the branch and open the PR
   *first*: PR CI takes about 17 minutes and the local suite about 6½, and nothing merges until
   both are green, so running them in series spends the local time twice. The threaded full suite
   is the gate: `JULIA_NUM_THREADS=auto julia --project -e 'using Pkg; Pkg.test()'`.
   - **Compare the pass count as a before/after pair** within one session: note what `main`
     reports before you start. A count that went *down* means a test stopped running.
   - **Read the summary, not just the exit code, for JET.** It runs only on the Julia minors in
     `JET_MINORS` (`test/runtests.jl`, the minor `Test.yml` pins), and in CI only on the ubuntu
     leg — so your local run is the one that sees JET on macOS or Windows (DECISIONS, "JET runs
     once, on ubuntu"). An off-allowlist run reports a `JET (SKIPPED — …)` testset.
     `test/jet.jl`'s header explains the allowlist. JET has rejected a design the whole suite
     accepted (#202's `apriltag_guess` union split).
   - Run Runic over the tracked sources (§2) after a large edit, and reindex every changed file.
   - **Review the diff before it leaves the branch** — `/mattpocock-skills:code-review` (Standards
     + Spec), plus the `julia-idiom-reviewer` subagent (§4). Name the review skill in full: a bare
     `/code-review` resolves to a different skill. Fan out to the other §4 auditors when the
     change earns them.
4. **Fix what fails, without asking.** Iterate until the suite is green, or until you cannot make
   confident progress. Only the second case is worth interrupting the user for.
5. **Write the PR description** — problem, solution, tradeoffs or limitations, and
   `Closes #<issue-number>` for the originating issue. Report the actual line delta against the
   estimate honestly: extracting shared code costs lines here, deleting a structure saves them.
6. **Watch the PR's CI** by polling `gh pr checks <n>` on its exit code (see the `gh` notes
   below). Not every PR gets every check: `TestOnPRs` triggers only on `src/**`, `test/**`,
   `*.toml` and `.github/workflows/**`; `Format` only on `**.jl` outside `simulation/`; `Lint` and
   `Docs` on their own `paths`. Read the workflow's filter before waiting on an absent check. A PR
   touching only `simulation/**` triggers **no check at all** (DECISIONS, "The simulation runs no
   CI and cuts no release"): its gate is `julia --project=simulation -e 'using Pkg; Pkg.test()'`.
7. **A red PR CI is an approval gate.** Investigate the root cause, determine the fix, explain the
   reasoning — and **ask before changing anything to make CI pass.**
8. **Merge only after every required check has passed.**
9. **Watch what the merge triggers.** The chain is `push to main → Test (full matrix) →
   AutoRelease (bump, tag, GitHub release) → Docs on the new tag → /stable/ advances`, about
   12 minutes (RELEASING.md carries the timings). A run that takes *far* longer is usually a cold
   depot cache. The tag's `Docs` build does not appear in `gh run list --branch main`, so a watcher
   scoped to `main` reports the chain complete early. `Lint` and `Format` are deliberately not
   gating. Confirm the originating issue is closed by the merged PR.
10. **A red post-merge workflow is an approval gate**, on the same terms as step 7.
11. **Clean up.** `git checkout main && git pull` — the bot's bump commit leaves local `main` one
    behind after every release — then delete the **local** fix branch. The repository deletes
    merged remote branches by itself, so `git push origin --delete` just fails.

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
  workflows has already happened once. Paraphrase instead ("the skip-CI token").
- **What does and does not release** — `Test.yml`'s `paths-ignore` is the single source of truth,
  because `AutoRelease` triggers on `Test` completing. It ignores top-level `*.md` (`*` does not
  cross `/`, so `docs/src/*.md` still counts), `LICENSE`, `.gitignore`, `codecov.yml`,
  `.lychee.toml`, `.copier-answers.yml`, **`docs/agents/**`**, **`.claude/**`**, **`.codex/**`**,
  **`.agents/**`** and **`simulation/**`**. Everything else under `src/` or `docs/` releases — so
  batch a `docs/src/` correction into the PR that needs it, or it costs a second version bump.
  `docs/agents/**` and the three agent-config trees look like they release, and do not: none is
  loaded by the package or built into the site. A PR touching only them gets `Lint` alone.
  `simulation/**` is excluded because it is a package in development that runs no CI until it is
  trusted (#289, #297).
- **`gh pr checks <n>` is the polling primitive.** Plain, it exits 8 while any check is pending,
  0 when all passed, 1 when one failed. **Adding `--json` drops that exit code** — it exited 0 with
  three checks pending (#269) — so take the exit code from a plain call and use `--json
  name,bucket` only to print progress. Poll in a loop rather than with `--watch`, which has emitted
  nothing at all when backgrounded. Same rule for the post-merge chain with `gh run list`.
- **Give every polling loop a heartbeat and a failure branch.** Any query that breaks behind
  `2>/dev/null` becomes a watcher that polls forever and says nothing, indistinguishable from slow
  CI; a filter that only matches success is silent through a crash. Run the query once on its own
  first, or print a first-iteration line.
- **A `gh` failure is a real failure** (gh is 2.100.0); investigate it rather than reaching for
  `gh api` as a version workaround.

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
Delivering the work still follows §6, not a skill's generic git workflow.

- **Issue tracker** — GitHub issues on `yakir12/Fromage.jl`, via `gh`. See
  `docs/agents/issue-tracker.md`.
- **Triage labels** — the five canonical roles, each label string equal to its name, all five
  already on the repo (`/triage` only applies labels, never creates them). See
  `docs/agents/triage-labels.md`.
- **Domain docs** — single-context: `CONTEXT.md` at the root, with `DECISIONS.md` standing in for
  `docs/adr/`. See `docs/agents/domain.md`.
