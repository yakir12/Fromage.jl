# Fromage.jl — Codex entry point

Fromage is the Dacke lab's Julia video pipeline: organise and verify lab footage,
build rectifications, track targets, convert tracks to real-world coordinates,
and render diagnostic video. Julia **1.13 or newer**; the tested minor is 1.13.
One package, version and suite; the former packages are submodules.

## Bootstrap and shared rules

Before repository work, read `CLAUDE.md` completely as the shared operational
reference. Preserve it and everything under `.claude/`. Its Julia, testing,
search, troubleshooting and review guidance also applies to Codex, with the
following explicit tool and authorization adaptations:

- **This entry point governs Codex authorization.** A request to implement permits
  local implementation and validation. Commit only when requested. Pushes
  (especially to `main`), PR creation/merge, tags, releases, workflow dispatch,
  remote changes and publication require explicit user instruction covering those
  actions. CLAUDE.md §6's implicit shipping authorization does not apply to Codex.
  Once authorized, follow its applicable delivery checks without asking repeatedly.
- Before naming anything, read `CONTEXT.md`. Before removing anything or changing
  a historical/architectural choice, read `DECISIONS.md`. Before behavior changes,
  read the relevant code, tests and decisions; reproduce bugs, add the regression
  test, then fix. Record scientific changes' assumptions and rationale.
- Before the first Kaimon eval, test or semantic search, use `$kaimon-up` from
  `.agents/skills/kaimon-up/SKILL.md`. Read `usage_instructions` first; take the
  quiz when new to Kaimon. Resolve this checkout's root; paths in old prompts are
  examples from the original machine, never a reason to access another checkout.
- Use `search_code(query="…", collection="fromage")` to discover code, then
  `grep_code` to confirm current paths/lines; inspect types/methods before claiming
  behavior. Explicitly target every session-bound call. Never evaluate in a
  borrowed session. If startup returns an already-running session you do not own,
  use `JULIA_NUM_THREADS=auto julia --project` for runtime evidence.
- If embeddings fail, use Kaimon's lexical search and `grep_code`. If Kaimon itself
  is unavailable, disclose that fact and use shell search with `# kaimon-ok`.
  Do not describe that fallback as complete semantic coverage.
- `KaimonGate.stash` takes a **String** key. Return expressions with `q=false`;
  printed output is stripped. Revise reloads source automatically. Poll background
  evaluations/tests while doing independent work.
- Reindex settled edits with `qdrant_reindex_file`, including tests/docs, when
  index writes are within the task's scope. If the task forbids service mutations,
  report reindexing as deferred. Confirm indexed lines against the working tree.

## Code and validation

`src/Fromage.jl` owns load-bearing include order. `src/main.jl` orchestrates the
pipeline; `paths.jl`, `shareio.jl`, `parsing.jl`, `probing.jl`, `gateway.jl` are
shared plumbing. `src/Rectifications/` owns geometry, `src/PawsomeTracker/`
tracking, and `src/VerifyRuns/` / `src/VerifyRectifications/` the CSV gateways.
`simulation/` is a separate package with its own local suite, no CI or release.

Follow CLAUDE.md §3: multiple dispatch, concrete parametric fields, explicit
imports from owners, small methods, preserved error evidence, and OhMyThreads.
Keep one definition site per parameter: every `Tuning`/`Segment` field is a CSV
column, every builder keyword is a rectification CSV column, `track` has no kwargs.
No open keyword forwarding, type piracy, abstract fields or unrelated refactors.
Read coordinate conventions in CONTEXT.md; units are not necessarily SI.

For targeted tests, include `test/fixtures.jl`, `test/harness.jl`, then the
selected suite using the test environment; inspect its imports first. Run the
full gate from the root with:

```sh
JULIA_NUM_THREADS=auto julia --project -e 'using Pkg; Pkg.test()'
```

Expect roughly 6–10 minutes with installed dependencies. Fixtures use synthetic
ffmpeg media, not lab footage or hardware. Read `test/runtests.jl` and
`test/quality.jl`; confirm JET actually ran on an allowed minor. Persistent-task
testing is a separate network-dependent, non-gating check. Read
`WHY-THE-SUITE-IS-SLOW.md` before proposing cuts. Read the CIFS investigations
before changing share retries; local tests cannot establish live-share behavior.

Use Runic in `@runic`, **not** Kaimon's `format_code`; the exact check is in
CLAUDE.md §2. For a publication-free documentation build use
`julia --project=docs docs/agents/build-local.jl` after installing the docs
environment. `docs/make.jl` also deploys; do not execute it for routine validation.
Integration checks: `python3 docs/agents/validate-codex.py`.

## Delegation and reusable workflows

For independent subsystem questions, delegate in parallel to the six native
`.codex/agents/*.toml` specialists: `implementation-scout`, `test-auditor`,
`docs-auditor`, `numerics-auditor`, `performance-auditor`, `julia-idiom-reviewer`.
Their original prompts remain canonical under `.claude/agents/`. Investigators
are read-only; only the main agent edits. Give each an exact question, checkout
root, `collection="fromage"`, and require locations plus runtime/test evidence.
Confirm their claims yourself. Single-file work usually needs no fan-out.

Use `$fromage-implement` for a ticket/spec and `$thermo-nuclear-code-quality-review` for
an explicitly requested strict maintainability review. These are Codex skills,
not Claude slash commands. Generic engineering skills are optional local
dependencies; each wrapper specifies a fallback if they are missing.

## Git, release and stop conditions

Read `RELEASING.md` before any authorized delivery operation. Never manually edit
the root package version or casually place release/skip-CI markers in commit
messages or PR text. A successful `main` test run starts automatic release and
tag documentation deployment. Recovery examples are not permission to run them.
Read actual workflow filters: `.claude/**`, `.codex/**`, `.agents/**`,
`docs/agents/**`, root Markdown and `simulation/**` are excluded from releases.
Package source and user-site docs release. Do not edit generated
manifests, docs/build, caches, coverage, transcripts or indexes as source files.

When delivery is authorized: one fix/branch/PR, start from main without stacking,
run required local and CI gates, review Standards + Spec plus Julia idioms,
poll `gh pr checks` (plain exit 8 means pending; no `--watch`), and verify the
post-merge release/tag/docs chain before cleanup. A red PR or post-merge workflow
requires diagnosis and user approval before changes to make it pass. Preserve
dirty user changes. Stop for unclear scientific assumptions, wrong Julia project,
missing required credentials or authority, or an unsafe operation; explain the
specific blocker. Never guess a successful result.

Keep secrets in environment variables or user configuration. Project and hook
trust are separate; until `/hooks` reports trusted hooks, deterministic hook
enforcement is inactive. See `docs/agents/codex.md` for setup, feature limitations,
the complete compatibility matrix and synchronization checks.
