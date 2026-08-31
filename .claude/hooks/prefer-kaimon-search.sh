#!/usr/bin/env bash
# PreToolUse/Bash: steer CODE DISCOVERY to Kaimon (CLAUDE.md §2 "Finding code").
#
# Why this exists: the session-level "prefer Bash" guidance and CLAUDE.md's
# "prefer Kaimon" guidance conflict, and prose lost. This makes the repo rule
# the one that is actually enforced.
#
# Scope is deliberately narrow — SEARCH verbs only. Reading files with
# cat/sed/head is untouched; so are git, ls, julia, and pipelines that merely
# post-process. Deliberate override: append  # kaimon-ok  to the command.
set -uo pipefail

cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

case "$cmd" in *'# kaimon-ok'*) exit 0 ;; esac

# A search verb in command position: start of line, or after ; & | ( or $(
at_cmd='(^|[;&|(]|\$\()[[:space:]]*(sudo[[:space:]]+)?'
[[ $cmd =~ ${at_cmd}(grep|egrep|fgrep|rg|ag|ack|find|fd)[[:space:]] || $cmd =~ ${at_cmd}git[[:space:]]+grep[[:space:]] ]] || exit 0

names_code_dir='(^|[[:space:]"'"'"'./])(src|test|docs|benchmark|examples)/'
recursive_grep='(^|[;&|(]|\$\()[[:space:]]*(sudo[[:space:]]+)?(git[[:space:]]+)?e?grep[[:space:]]+(-[a-zA-Z]*[rR])'
repo_wide_tool="${at_cmd}((rg|ag|ack)|git[[:space:]]+grep)[[:space:]]"

if   [[ $cmd =~ $names_code_dir ]]; then why="it searches this repo's code directories"
elif [[ $cmd =~ $recursive_grep ]]; then why="it is a recursive grep over the tree"
elif [[ $cmd =~ $repo_wide_tool ]]; then why="rg/ag/ack/git-grep search the repo tree"
else exit 0
fi

jq -nc --arg why "$why" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Blocked by .claude/hooks/prefer-kaimon-search.sh: \($why).\n\nCLAUDE.md section 2 - use Kaimon for code discovery, which shell grep cannot do:\n  - Describing behaviour / exploring -> search_code(query=\"...\", collection=\"fromage\")  [semantic; finds code you did not know to grep for]\n  - Holding an exact token           -> grep_code(pattern=\"...\")  [regex over the live tree, hits carry their enclosing symbol]\n  - Then pin it down                 -> type_info / search_methods / goto_definition / document_symbols\n\nRe-issue this as a Kaimon call. If shell really is the right tool here (piping matches onward, searching outside the repo, non-code files), append  # kaimon-ok  to the command and it will run.")
  }
}'
