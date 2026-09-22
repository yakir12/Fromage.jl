---
name: fromage-implement
description: Implement a Fromage issue or agreed spec with test-first slices, Standards and Spec review, Julia idiom review, and authorized delivery gates.
---

Input: an issue/spec and agreed scope. Read AGENTS.md and the complete
`.claude/skills/implement/SKILL.md`. Follow its test-first and review procedure.
Use the Codex `tdd` and `code-review` skills if installed, not Claude's
plugin-qualified slash commands. If unavailable, reproduce the bug, write a
failing regression test, implement the smallest fix and run the targeted suite;
then delegate independent Standards and Spec reviews with the source issue and
diff, plus `julia-idiom-reviewer` for Julia edits. Reviewers remain read-only.

AGENTS.md's authorization boundary overrides the shared skill's shipping step:
finish local implementation, validation and review; commit only when requested,
and perform remote delivery only when explicitly authorized. For authorized
delivery, read CLAUDE.md §6 and RELEASING.md and follow their gates. A red PR or
post-merge workflow requires diagnosis and approval before changing it.

Completion: report scope, changed files, reproduction/regression evidence,
threaded suite result, review findings, index freshness, issue-closure status, and
any delivery steps not authorized or blocked. Include `Closes #<issue-number>` in
the PR description and verify the originating issue closed after merge. A local
result is not a completed release.
