# Fromage.jl — Codex entry point

Fromage is the Dacke lab's Julia video pipeline: organise and verify lab footage,
build rectifications, track targets, convert tracks to real-world coordinates,
and render diagnostic video. Julia **1.13 or newer**; the tested minor is 1.13.
One package, version and suite; the former packages are submodules.

## Bootstrap and shared rules

Before repository work, read `CLAUDE.md` completely as the shared operational
reference. Claude and Codex both maintain this repo, and `CLAUDE.md` plus
`.claude/` are the single source for both: change a shared rule, agent prompt or
skill there, and keep this file and the `.codex/`/`.agents/` wrappers to the
Codex-specific adaptations below. Its Julia, testing, search, troubleshooting and
review guidance applies to Codex with these explicit adaptations:

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
  behavior. Explicitly target every session-bound call. An already-running
  agent-spawned Fromage session is usable once `investigate_environment` confirms
  its project; never evaluate in another project's session or the user's own REPL.
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

The repo map, Julia idioms and invariants, and test, formatting and index
procedures are CLAUDE.md §§1–3, unadapted: follow them as written. What differs
for Codex:

- Julia runs in the `workspace-write` sandbox with networking off, so the full
  threaded suite may need escalation for depot/cache writes; request it rather
  than skipping the gate.
- For a publication-free documentation build use
  `julia --project=docs docs/agents/build-local.jl` after installing the docs
  environment. `docs/make.jl` also deploys; do not execute it for routine
  validation.
- Integration checks: `python3 docs/agents/validate-codex.py` — run it after any
  change to `CLAUDE.md`, `AGENTS.md`, `.claude/`, `.codex/`, `.agents/` or
  `docs/agents/`; it fails when a Claude agent or skill lacks its Codex wrapper.

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
the root package version, and never let a skip-CI or version-bump token appear
in a commit message or PR body, even when writing about one — paraphrase it. A successful `main` test run starts automatic release and
tag documentation deployment. Recovery examples are not permission to run them.
Read actual workflow filters: `.claude/**`, `.codex/**`, `.agents/**`,
`docs/agents/**`, root Markdown and `simulation/**` are excluded from releases.
Package source and user-site docs release. Do not edit generated
manifests, docs/build, caches, coverage, transcripts or indexes as source files.

When delivery is authorized: one fix/branch/PR (agent-configuration changes batch
on one branch and one PR, per CLAUDE.md §6), start from main without stacking,
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
