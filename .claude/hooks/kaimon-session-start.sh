#!/usr/bin/env bash
# SessionStart: report LIVE Kaimon state into context.
#
# Deliberately not a copy of CLAUDE.md or AGENTS.md — both are already loaded
# every session, so re-injecting their rules buys nothing. What a hook can add is
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
  msg="Kaimon MCP: up on localhost:${PORT} (HTTP ${code} at session start). This conversation has no
Julia session of its own yet: run the kaimon-up skill before the first ex, run_tests or search_code."
fi

jq -nc --arg m "$msg" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
