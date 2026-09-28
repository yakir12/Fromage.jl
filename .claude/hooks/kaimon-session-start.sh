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
# A server that is up but busy (indexing collections just after it starts) can take seconds to
# answer. On 2026-09-28 the old 2 s limit timed out on a server whose log shows it answering that
# very request, and the session was told Kaimon was down and worked without it. So a timeout
# (curl exit 28) is not "down"; only a refused or failed connection is. 4 s leaves the probe
# inside the 5 s hook timeout.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://localhost:${PORT}/mcp" 2>/dev/null)
rc=$?

if [ "$rc" = 28 ]; then
  msg="Kaimon MCP: SLOW on localhost:${PORT} (no answer within 4 s at session start; it is likely busy
indexing). Treat it as up: call the kaimon ping tool, and use Kaimon as normal if it answers. Fall back to
shell search only if ping fails too. Then run the kaimon-up skill before the first ex, run_tests or search_code."
elif [ "$rc" != 0 ] || [ "${code:-000}" = "000" ]; then
  msg="Kaimon MCP: NOT REACHABLE on localhost:${PORT} (checked at session start, curl exit ${rc}).
Kaimon may still come up later in the session: call the kaimon ping tool before you rely on this.
If ping fails too, code discovery via search_code/grep_code is unavailable. Shell grep/rg is the
legitimate fallback while it is down — append '# kaimon-ok' to get past the PreToolUse hook,
and say plainly in your answer that findings came from shell grep, not a semantic search.
If the user expects Kaimon, tell them the server looks down rather than silently working around it."
else
  msg="Kaimon MCP: up on localhost:${PORT} (HTTP ${code} at session start). This conversation has no
Julia session of its own yet: run the kaimon-up skill before the first ex, run_tests or search_code."
fi

jq -nc --arg m "$msg" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
