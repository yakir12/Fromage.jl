---
name: kaimon-up
description: Bring up and verify Kaimon, Julia project routing, Revise and semantic search before the first Fromage eval, test or code search.
---

Read AGENTS.md and the complete `.claude/skills/kaimon-up/SKILL.md` from the
repository root. Execute that shared procedure with these Codex adaptations:

1. Resolve the current checkout root and replace the historical absolute path
   in every call. Read `usage_instructions`; if new to Kaimon, answer and self-grade
   `usage_quiz` before evaluating. Use String stash keys despite the quiz example.
2. Invoke the configured `kaimon` MCP tools by their available client names.
   Fan out independent health checks, explicitly passing `collection="fromage"`.
   Also call `qdrant_list_collections`; it must list `fromage`.
3. Only use a session this conversation started. If `start_session` returns an
   already-running session instead of creating one, do not borrow it. Report
   the limitation and use `JULIA_NUM_THREADS=auto julia --project` locally.
4. Confirm the active project and Revise before the smoke eval. Check a live
   `src/shareio.jl` hit against `grep_code`; exact ranking is not stable and a
   changed top-five order alone is not evidence of a broken index.
5. If semantic search fails, try `mode="lexical"` and `grep_code`. If the server
   is down, disclose it and use the documented `# kaimon-ok` shell fallback.
   Diagnose auth/port/project allowlist using `docs/agents/codex.md`; do not
   expose credentials, install dependencies or rebuild the collection silently.

Return session ownership, project, Julia/package versions, thread count, Revise
status, canary result and index evidence. Label each unverified layer explicitly.
