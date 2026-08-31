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
Always pass collection=\"fromage\" — claude_dir_fromage also exists and is empty, so a domain query
against it returns nothing and looks like 'no such code'.
Still run investigate_environment() before any 'ex' call: a REPL whose pwd is this repo may have the
global v1.12 environment active, and 'ex' is only correct when the active project is Fromage.jl.
Fire one cheap grep_code at src/ early — Kaimon's access prompt errors after ~50s unanswered, so it
is better triggered in the first minute than an hour in."
fi

jq -nc --arg m "$msg" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
