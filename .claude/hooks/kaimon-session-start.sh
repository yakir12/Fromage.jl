#!/usr/bin/env bash
# SessionStart: report LIVE Kaimon state into context.
#
# Deliberately not a copy of the CLAUDE.md §2 checklist — that prose is already
# loaded every session and re-injecting it buys nothing. What a hook can add is
# state CLAUDE.md cannot know: whether the server is actually up right now.
#
# It also closes a gap in prefer-kaimon-search.sh: if Kaimon is down, that hook
# would deny shell search with no working alternative. Saying so up front turns
# that dead end into a documented fallback.
set -uo pipefail

PORT=${KAIMON_PORT:-2828}
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://localhost:${PORT}/mcp" 2>/dev/null) || code=000

if [ "$code" = "000" ]; then
  msg="Kaimon MCP: NOT REACHABLE on localhost:${PORT} (checked at session start).
Code discovery via search_code/grep_code is unavailable this session. Shell grep/rg is the
legitimate fallback while it is down — append '# kaimon-ok' to get past the PreToolUse hook,
and say plainly in your answer that findings came from shell grep, not a semantic search.
If the user expects Kaimon, tell them the server looks down rather than silently working around it."
else
  msg="Kaimon MCP: up on localhost:${PORT} (HTTP ${code} at session start).
Ground rule 6 applies: search_code(query=..., collection=\"fromage\") to find, grep_code to confirm.
Always pass collection=\"fromage\" — without it search_code falls back to the last-used session's
project, which may be another repo's collection, and a miss there looks like 'no such code'.
KaimonGate.stash takes a String key; the Kaimon quiz's stash(:key, v) throws a MethodError.
A new conversation has no Julia session of its own. Run the kaimon-up skill before the first ex, run_tests
or search_code: it starts your own session, checks the active project and Revise, fires the
access-prompt canary and proves the Qdrant index is live — in the first minute, not mid-task."
fi

jq -nc --arg m "$msg" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
