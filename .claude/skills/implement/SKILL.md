---
name: implement
description: Build a ticket or spec in Fromage.jl — test-first at agreed seams, reviewed before it moves, then shipped through the CLAUDE.md §6 sequence. Use for implementing an issue, a spec, or a tracer-bullet ticket in this repo.
disable-model-invocation: true
---

# Implement (Fromage.jl)

Build the work described in the ticket or spec.

This skill deliberately claims the bare `/implement` name. The plugin skill of the same name
(`/mattpocock-skills:implement`) is written to be generic across repos, and its final
instruction — *"commit your work to the current branch"* — is wrong here: a commit that lands
on `main` cuts a release (§6, "Green CI on `main` *is* the release"). Use this one.

## 1. Build it test-first

Drive `/tdd` at the seams the plan already agreed — one red-green slice at a time. For a bug,
the reproduction comes first, then the regression test, then the fix (CLAUDE.md §1.5).

Run a single suite while iterating rather than the whole thing; §2 of CLAUDE.md describes how
to include `test/fixtures.jl` + `test/harness.jl` and then just the file you care about.

## 2. Review the diff before it moves

Two passes, neither optional for a change of any size:

- `/code-review` over the diff.
- The `julia-idiom-reviewer` subagent (CLAUDE.md §4) — this is the axis that most often slips,
  and it knows the repo's structural invariants (#140/#141's one-definition-site rule, explicit
  imports, dispatch over flags).

Fan out to the other auditors in §4 when the change earns them: `numerics-auditor` for anything
touching rectification, distortion or pose; `performance-auditor` for a hot path;
`test-auditor` and `docs-auditor` when coverage or user-visible behaviour moves.

Verify an agent's claim before acting on it, especially a line number (§4).

## 3. Ship it through CLAUDE.md §6

**Do not commit to the current branch.** Follow §6's sequence as written — branch off `main`,
the threaded full suite as the local gate, `format_code`, reindex every touched file, PR, the
two approval gates on red CI, merge, watch the post-merge release chain, clean up.

§6 is the single definition site for that sequence; it is not restated here, on the same
principle the package enforces in code (§3, #140/#141). Read it there.
