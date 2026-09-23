#!/usr/bin/env bash
# PreToolUse/Bash: send searches of this repo's Julia code to Kaimon (CLAUDE.md §1 rule 6).
# The logic lives in prefer_kaimon_search.py, which tokenises the command properly; this
# wrapper keeps the path both .claude/settings.json and .codex/hooks.json register.
# No python3 → fail open rather than block every shell call.
command -v python3 >/dev/null 2>&1 || exit 0
exec python3 "$(dirname "${BASH_SOURCE[0]}")/prefer_kaimon_search.py"
