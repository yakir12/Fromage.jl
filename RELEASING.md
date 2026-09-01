# How releases work

**You never release manually.** Every push to `main` that passes CI is released
automatically. This document explains the machinery, the commit-message rules that
control it, and how to recover when something goes wrong. The audience is a future
maintainer (human or AI); lab users never need any of this.

## The chain

```
push to main
  └─► Test workflow (full matrix: Linux, Intel mac, Windows)
        └─ on success ─► AutoRelease workflow (.github/workflows/AutoRelease.yml)
              1. guard: is the tested commit still main's HEAD? if not, stop
              2. bump `version` in Project.toml (patch, unless overridden — see below)
              3. commit "Release vX.Y.Z [skip ci]", tag vX.Y.Z, push both atomically
              4. create a GitHub release with auto-generated notes
              5. dispatch the Docs workflow on the new tag
                    └─► docs build for the tag ─► /stable/ on github.io advances
```

Expect a release to land roughly **15–35 minutes after the push** — the Test matrix is
the wait, and the macOS Intel runner is usually the long pole (slow to queue). "I
pushed and nothing happened yet" is almost always just queue time; only start
debugging if the Test run itself has finished green and no release appeared.

Consequences of the design:

- **Green CI on `main` *is* the release process.** There is no dev grace period; the
  10 lab users always get the latest commit that passed the test matrix.
- Every green push produces exactly one release. There is no mechanism to batch
  several pushes into one version — if that is ever wanted, push to a branch and
  merge once.
- Documentation-only changes also release (a patch bump). That is intentional: it is
  what moves `/stable/` on the docs site.

## Commit-message rules

The **head commit of the push** (only that one) controls the behavior.

### Tokens you may use on purpose

| token in message | effect |
| --- | --- |
| *(none)* | patch bump: `0.1.5 → 0.1.6` |
| `#minor` | minor bump: `0.1.5 → 0.2.0` |
| `#major` | major bump: `0.1.5 → 1.0.0` |

### Tokens you must NOT write accidentally

- **The GitHub skip-CI tokens** — `[skip ci]`, `[ci skip]`, `[no ci]`,
  `[skip actions]`, `[actions skip]`, or a `skip-checks` trailer — anywhere in the
  message (subject *or body*) make GitHub run **no workflows at all** for that push:
  no tests, and therefore no release and no docs deploy. This has already happened
  once: the commit that *introduced* AutoRelease described the bot's bump commit in
  its message body, GitHub honored the token, and the push silently ran nothing.
  When writing about these tokens, paraphrase ("the skip-CI token") instead of
  quoting them.
- **The bump tokens**, for the same reason: a message body that casually contains
  the literal minor/major token (e.g. quoting this table) will bump more than you
  meant. Paraphrase when writing *about* them.

The bot's own bump commit legitimately carries the skip token — that is what
prevents an infinite release loop (bump commit → Test → AutoRelease → bump …).

## Rules for the maintainer

- **Never edit `version` in `Project.toml`.** The bot owns it. A manual edit will at
  best be overwritten and at worst make the bot's `sed` produce a nonsense version.
- **Never push tags manually** while AutoRelease exists — you would race the bot for
  the same version number. (If you must, see "Manual release" below.)
- **`git pull` after every push** before committing again: the bot adds a bump
  commit on top of yours, so your local `main` is one commit behind after each
  release.
- Two pushes in quick succession are safe: when the first push's Test finishes, the
  guard sees that `main` has moved on and skips; only the newest push releases. The
  intermediate commit simply never gets its own version.
- **...unless the newer push is one that skips the test workflow.** "Only the newest
  push releases" assumes the newest push *runs* Test. A push touching only the
  paths-ignored files — top-level `*.md` and the handful beside it — runs nothing, so
  it cannot release. It has still moved `main` past the tested commit, which makes the
  guard skip the release the *previous* push had earned. The result is a merge that is
  green everywhere and never released, with nothing left to trigger a retry. **Avoid
  pushing a docs-only change to `main` while a release is in flight** — wait for the
  tag, or accept that the next `src/` or `docs/` push will release both together. This
  happened on 2026-09-01: PR #163 merged, and a `CLAUDE.md` push landed before its Test
  run had finished.

## Subtleties that will bite you if you refactor this

- **Tags pushed with `GITHUB_TOKEN` do not trigger workflows** (GitHub's
  anti-recursion rule). That is why AutoRelease explicitly runs
  `gh workflow run Docs.yml --ref vX.Y.Z` (step 5), and why `Docs.yml` must keep its
  `workflow_dispatch` trigger. Delete either and `/stable/` silently stops
  advancing while everything else looks green. (Documenter deploys on
  `workflow_dispatch` events — verified in `deployconfig.jl`; keep that in mind if
  you ever change the docs stack.)
- **AutoRelease is gated on the Test workflow only** — Lint (the lychee link
  checker) can fail without blocking a release. A dead external link should not
  stop the lab from getting a tracker fix. Reconsider if Lint ever checks something
  release-critical.
- The `workflow_run` trigger matches the Test workflow **by its `name:`** — renaming
  `Test` in `Test.yml` without updating `AutoRelease.yml` disables all releases,
  silently.
- The guard compares `github.event.workflow_run.head_sha` to `main`'s HEAD, and the
  branch + tag push is `--atomic`, so a race can at worst fail the push loudly —
  never half-release.
- **AutoRelease reports `success` when it skips.** The guard sets an output and the
  remaining steps report `skipped`, which is not a failure — so the job is green, every
  workflow on the dashboard is green, and there is no tag and no release. A green run is
  therefore *not* evidence that a release happened; the new tag is. Check
  `gh api repos/yakir12/Fromage.jl/releases/latest --jq .tag_name`, or `version` in
  `Project.toml` on `main`. (`gh release list --json` is not available on the `gh` in
  this environment; `gh api` and `gh release view --json` are.)
- **A skipped release cannot be rescued with `workflow_dispatch`.** AutoRelease requires
  `github.event.workflow_run.event == 'push'`, so a hand-dispatched Test run finishes
  green and triggers nothing at all. The only things that restart the chain are a real
  push to `main` that Test actually runs on, or a manual release.
- The bump `sed` assumes `Project.toml` has a top-level `version = "X.Y.Z"` line
  (it does; it's a standard Julia package). A `[workspace]` member with its own
  `version` line would not be touched (good), but keep the anchored `^version`
  pattern if you edit the script.

## Recovery

**AutoRelease failed between steps** (e.g. tag pushed, release creation failed):
finish by hand — the steps are independent:

```sh
gh release create vX.Y.Z --generate-notes     # if the release is missing
gh workflow run Docs.yml --ref vX.Y.Z         # if /stable/ didn't advance
```

**A merge went green but never released** (no new tag; AutoRelease reports success with
its later steps `skipped`): `main` moved past the tested commit before that commit's Test
run finished — usually because a docs-only push followed the merge. See the maintainer
rule above. Nothing is broken and nothing needs undoing; the merge is on `main`, just
unreleased. Land the next change that touches `src/` or `docs/` and its push runs Test,
the guard passes, and one release carries both. Prefer that to a manual release: a
hand-pushed tag races the bot for the next version number.

**A bad version was released**: don't delete tags (users may have pinned them).
Push a fix; the next green push releases the corrected version minutes later.
That's the whole point of the design.

**Manual release** (only if AutoRelease is broken or removed): set `version` in
`Project.toml`, commit, `git tag vX.Y.Z && git push origin main vX.Y.Z`. A tag
pushed by a *human* (unlike the bot) triggers the Docs and Test workflows by
itself, so nothing else is needed.

**Skipping a release for one push**: there is no run-tests-but-don't-release token.
The skip-CI token skips everything including tests. If a real need appears, add a
no-release token check to the guard step in `AutoRelease.yml`.
