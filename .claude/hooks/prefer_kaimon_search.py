#!/usr/bin/env python3
"""PreToolUse/Bash: send searches of this repo's *Julia code* to Kaimon (CLAUDE.md §1 rule 6).

Everything else runs: grep over markdown/TOML/YAML, grep as a pipe filter, text that merely
mentions `src/` inside a quoted commit message or PR body, paths outside the repo, and file
listing (`find`, `fd`) — none of those is a search of Julia code.

The previous version regex-matched the whole command string ("a search verb anywhere" plus
"src/ anywhere"). Replayed over 99 session transcripts (2026-09-23), about 71% of its 157
denials were false positives, and 1,177 of the 1,733 `# kaimon-ok` escapes were written for
commands it would not have blocked: an escape used out of habit carries no signal. So this
version tokenises the command and judges each search command by what it actually reads. On
the same 7,431 historical commands it denies 403 where the old one denied 766; the two it
alone denies are real searches of simulation/src/*.jl, and a sweep of what it newly allows
found no Julia search it misses. Allow/deny fixtures for each branch
live in docs/agents/validate-codex.py.

Deliberate override: append  # kaimon-ok  to the command. Any internal error fails open
(the command runs) — a guardrail must never be the thing that breaks a session.
"""

import fnmatch
import glob
import json
import os
import re
import shlex
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEPARATORS = {"|", "||", "&&", ";", "&", "(", ")", "\n", "|&"}
WRAPPERS = {"sudo", "command", "time", "nice", "env", "exec"}
SEARCHERS = {"grep", "egrep", "fgrep", "rg", "ag", "ack"}
# Options whose value is the next token (when not attached with `=` or glued to a short flag).
VALUED = {
    "grep": {"-e", "-f", "-m", "-A", "-B", "-C", "-d", "-D", "--regexp", "--file", "--max-count",
             "--after-context", "--before-context", "--context", "--directories", "--devices",
             "--include", "--exclude", "--exclude-dir", "--label", "--color", "--colour"},
    "rg": {"-e", "-f", "-g", "-t", "-T", "-m", "-A", "-B", "-C", "-M", "-j", "-E", "-d",
           "--regexp", "--file", "--glob", "--iglob", "--type", "--type-not", "--type-add",
           "--max-count", "--after-context", "--before-context", "--context", "--max-columns",
           "--threads", "--encoding", "--max-depth", "--sort", "--sortr", "--color", "--colors"},
    "git grep": {"-e", "-f", "-m", "-A", "-B", "-C", "--max-depth", "--threads", "--max-count",
                 "--after-context", "--before-context", "--context", "--color", "-O", "--open-files-in-pager"},
}
VALUED["ag"] = VALUED["ack"] = VALUED["rg"] | {"-G", "--file-search-regex", "--ignore", "--ignore-dir"}


def strip_heredocs(cmd):
    """Drop heredoc bodies: they are data fed to a command, never a command line."""
    out, delim = [], None
    for line in cmd.split("\n"):
        if delim is not None:
            if line.strip() == delim:
                delim = None
            continue
        out.append(line)
        m = re.search(r"<<-?\s*(['\"]?)(\w+)\1", line)
        if m:
            delim = m.group(2)
    return "\n".join(out)


def simple_commands(cmd):
    """Yield (words, fed_by_pipe) for each simple command, quotes resolved by shlex."""
    lex = shlex.shlex(strip_heredocs(cmd), posix=True, punctuation_chars="();<>|&\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = "#"
    words, piped, skip_next = [], False, False
    for tok in lex:
        if tok in SEPARATORS or tok == "$":
            if words:
                yield words, piped
            words, piped = [], tok in {"|", "|&"}
            continue
        if set(tok) <= set("<>&"):  # a redirection: its target is a file, not an operand
            skip_next = True
            continue
        if skip_next:
            skip_next = False
            continue
        words.append(tok)
    if words:
        yield words, piped


def split_options(tool, args):
    """Return (options as (name, value) pairs, positional operands, operands after `--`)."""
    opts, operands, after = [], [], []
    valued, it = VALUED[tool], iter(args)
    for a in it:
        if a == "--":
            after = list(it)
            break
        if a.startswith("--"):
            name, eq, val = a.partition("=")
            opts.append((name, val if eq else (next(it, "") if name in valued else "")))
        elif a.startswith("-") and len(a) > 1:
            name = a[:2]
            if name in valued:
                opts.append((name, a[2:] or next(it, "")))
            else:  # bundled short flags, e.g. -rni
                opts.extend(("-" + ch, "") for ch in a[1:])
        else:
            operands.append(a)
    return opts, operands, after


def contains_julia(directory):
    for base, dirs, files in os.walk(directory):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d != "build"]
        if any(f.endswith(".jl") for f in files):
            return True
    return False


def julia_targets(tool, words, piped, cwd):
    """The in-repo Julia sources this search command reads, as display strings."""
    opts, operands, after = split_options(tool, words)
    names = {n for n, _ in opts}
    pattern_given = bool(names & {"-e", "-f", "--regexp", "--file"})
    if tool == "git grep":
        targets = after or ["."]  # operands before `--` are the pattern and revisions
        recursive = True
    else:
        targets = (operands if pattern_given else operands[1:]) + after
        recursive = tool != "grep" or bool(names & {"-r", "-R", "--recursive"}) or \
            ("--directories", "recurse") in opts or ("-d", "recurse") in opts
        if not targets:
            if piped or (tool == "grep" and not recursive):
                return []  # reading stdin: a pipe filter, not a search of the tree
            targets = ["."]

    includes = [v for n, v in opts if n in {"--include", "-g", "--glob", "--iglob", "-G"} and not v.startswith("!")]
    excludes = [v.lstrip("!") for n, v in opts if n in {"--exclude", "-g", "--glob", "--iglob"}
                and (n == "--exclude" or v.startswith("!"))]
    types = [v for n, v in opts if n in {"-t", "--type"}]
    not_types = [v for n, v in opts if n in {"-T", "--type-not"}]

    def filters_admit_julia():
        if includes and not any(fnmatch.fnmatch("x.jl", g.split("/")[-1]) for g in includes):
            return False
        if any(fnmatch.fnmatch("x.jl", g.split("/")[-1]) for g in excludes):
            return False
        if types and "julia" not in types:
            return False
        return "julia" not in not_types

    if not filters_admit_julia():
        return []
    hits = []
    for t in targets:
        if "$" in t or "`" in t or (cwd is None and not os.path.isabs(os.path.expanduser(t))):
            continue  # unresolvable here (a shell variable, or relative to an unknown `cd`)
        path = Path(os.path.expanduser(t))
        path = path if path.is_absolute() else Path(cwd) / path
        expanded = glob.glob(str(path)) if glob.has_magic(str(path)) else [str(path)]
        for p in map(lambda s: Path(os.path.normpath(s)), expanded):
            if not (p == ROOT or ROOT in p.parents):
                continue  # outside this repo: not Kaimon's to answer
            if p.is_dir() and recursive and contains_julia(p):
                hits.append(os.path.relpath(p, ROOT) + "/")
            elif p.suffix == ".jl" and p.is_file():
                hits.append(os.path.relpath(p, ROOT))
    return hits


def verdict(command, cwd):
    if "# kaimon-ok" in command:
        return None
    for words, piped in simple_commands(command):
        while words and (words[0] in WRAPPERS or re.fullmatch(r"\w+=.*", words[0])):
            words = words[1:]
        if not words:
            continue
        if words[0] in {"cd", "pushd"}:  # later relative paths resolve against the new directory
            dest = os.path.expanduser(words[1]) if len(words) > 1 else os.path.expanduser("~")
            cwd = None if ("$" in dest or cwd is None and not os.path.isabs(dest)) else \
                os.path.normpath(os.path.join(cwd, dest))
            continue
        if words[0] == "git":
            rest = words[1:]
            while rest and rest[0].startswith("-"):  # git -C dir / -c k=v take a value
                rest = rest[2:] if rest[0] in {"-C", "-c"} else rest[1:]
            if rest[:1] == ["grep"]:
                hits = julia_targets("git grep", rest[1:], piped, cwd)
                if hits:
                    return "git grep", hits
            continue
        tool = {"egrep": "grep", "fgrep": "grep"}.get(words[0], words[0])
        if tool in SEARCHERS:
            hits = julia_targets(tool, words[1:], piped, cwd)
            if hits:
                return words[0], hits
    return None


def main():
    try:
        data = json.load(sys.stdin)
        found = verdict(data.get("tool_input", {}).get("command", "") or "", data.get("cwd") or os.getcwd())
    except Exception as err:  # fail open, but say why on stderr
        print(f"prefer_kaimon_search.py: {type(err).__name__}: {err}; allowing", file=sys.stderr)
        return
    if not found:
        return
    tool, hits = found
    shown = ", ".join(hits[:3]) + (" …" if len(hits) > 3 else "")
    reason = (
        f"Blocked by .claude/hooks/prefer-kaimon-search.sh: `{tool}` searches this repo's Julia code ({shown}).\n\n"
        "CLAUDE.md §1 rule 6 — Julia code goes through Kaimon:\n"
        "  - Holding an exact token           -> grep_code(pattern=\"...\")  [regex over the live tree; hits carry their enclosing symbol]\n"
        "  - Describing behaviour / exploring -> search_code(query=\"...\", collection=\"fromage\")  [finds what you did not know to grep for]\n\n"
        "Shell search stays fine for non-Julia files, pipe filters and paths outside the repo. If shell really is right here, "
        "append  # kaimon-ok  to the command."
    )
    json.dump({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                      "permissionDecisionReason": reason}}, sys.stdout)


if __name__ == "__main__":
    main()
