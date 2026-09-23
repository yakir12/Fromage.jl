---
name: thermo-nuclear-code-quality-review
description: Perform an explicitly requested thermonuclear or especially strict maintainability review of a Fromage diff, focusing on structural simplicity and abstraction quality.
---

Read AGENTS.md and the complete
`.claude/skills/thermo-nuclear-code-quality-review/SKILL.md`; apply its full
review rubric and output priorities. Input is a diff plus its originating spec;
resolve the comparison base before reviewing. Read DECISIONS.md before proposing
removals and use current repository evidence, not index-only line numbers.

The shared skill is report-only: edit no files, and treat implementing a finding
as a separate request under AGENTS.md's authorization rules. Delegate independent
investigations to read-only specialists when useful. Preserve Julia idioms when
interpreting the generic abstraction examples in the shared rubric. If the base,
spec or runtime evidence is unavailable, state the gap and bound the findings.
Return actionable file:line findings ordered by structural impact, with proposed
simplifications and what must be verified; do not manufacture cosmetic blockers.
