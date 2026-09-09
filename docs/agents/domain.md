# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the
codebase. This repo is **single-context**.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — the domain model: what a run, segment, track, session,
  rectification, calibration, frame and space are, the seven coordinate spaces and their axis
  orders, and the rules that decide a name. `CLAUDE.md` §1 makes this mandatory **before naming
  anything**, and before claiming a term is ambiguous.
- **`DECISIONS.md`** at the repo root — this repo's decision record, standing in for `docs/adr/`.
  It records what was tried, measured and **not kept**, so read it **before removing anything**,
  or anything that looks gratuitously complicated. Entries cite issue numbers
  (`git log --grep '#nn'`).
- **`docs/adr/`** — does not exist here. If per-decision ADR files are ever introduced, read the
  ones touching the area you're about to work in; until then `DECISIONS.md` is the whole record.

Two long-form investigations sit beside them and are worth reading when the topic comes up:
`CIFS-SHARE-INVESTIGATION.md` and `WHY-FRAMES-FAIL.md` (the share's EAGAIN failures, and why the
retry loop stays).

Mechanism belongs in `src/` and `test/` comments, not in the two files above: if a fact has a line
of code to sit beside, that is its home.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest
creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and
`/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

```
/
├── CONTEXT.md                       ← the domain model and naming rules
├── DECISIONS.md                     ← what was tried, measured and not kept
├── CIFS-SHARE-INVESTIGATION.md
├── WHY-FRAMES-FAIL.md
├── docs/src/                        ← the user-facing Documenter site
└── src/
```

Multi-context layout (a root `CONTEXT-MAP.md` pointing at per-context `CONTEXT.md` files) is **not**
in use. `src/Rectifications/`, `src/PawsomeTracker/`, `src/VerifyRuns/` and
`src/VerifyRectifications/` are submodules of one package with one shared vocabulary, not separate
bounded contexts — deliberately so.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a
test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly
avoids — it also records which words were deliberately **left alone**, and those are decisions too.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language
the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag conflicts with DECISIONS.md

If your output contradicts a recorded decision, surface it explicitly rather than silently
overriding:

> _Contradicts the DECISIONS entry "Rectification builders take keywords, and are chosen by type",
> but worth reopening because…_

Cite the entry by its heading, and the issue number if it has one.
