---
name: kaimon-up
description: Bring up and verify Kaimon, Julia project routing, Revise and semantic search before the first Fromage eval, test or code search.
---

Read AGENTS.md and the complete `.claude/skills/kaimon-up/SKILL.md` from the
repository root. Execute that shared procedure with these Codex adaptations:

1. Resolve the current checkout root and replace the historical absolute path
   in every call.
2. Invoke the configured `kaimon` MCP tools by their available client names,
   fanning out the independent checks as the shared procedure lists them.
3. If semantic search fails, try `mode="lexical"` and `grep_code`. If the server
   is down, disclose it and use the documented `# kaimon-ok` shell fallback.
   Diagnose auth/port/project allowlist using `docs/agents/codex.md`; do not
   expose credentials, install dependencies or rebuild the collection silently.

Return session ownership, project, Julia/package versions, thread count, Revise
status, canary result and index evidence. Label each unverified layer explicitly.
