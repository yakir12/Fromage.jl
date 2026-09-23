# Codex setup and Claude compatibility

## Scope and verified versions

This integration was developed with **codex-cli 0.155.1**, Claude Code 2.1.278
and Julia 1.13.0 on Linux. It adds native Codex entry points and leaves
`CLAUDE.md`, every `.claude/` file, package source, tests and GitHub workflows
unchanged. The original prompts and scripts remain canonical shared resources.
No symlinks, package dependencies, model pins or credentials are added.

The migration was local only: no commit, push, PR, merge, tag, release, remote
configuration change or publication. `.codex/**` and `.agents/**` were at first
not excluded by `Test.yml`, so a push touching only them cut a release (v0.6.15
came from a 4-line `.codex/config.toml` commit). They are now ignored alongside
`.claude/**`, `docs/agents/**` and root Markdown.

## Start and trust

From the checkout root:

```sh
codex --version
codex
```

Review and accept the repository trust prompt. Project configuration, rules and
hooks load only for trusted projects. If trust needs manual repair, put an entry
in your **user** `~/.codex/config.toml` (use your real absolute checkout path):

```toml
[projects."/absolute/path/to/Fromage.jl"]
trust_level = "trusted"
```

Do not commit this machine-specific entry. In the CLI, open `/hooks`, inspect
both project hooks and trust their exact definitions. Hook trust is separate
from repository trust and is invalidated when definitions change. Until trusted,
hooks are registered but skipped; AGENTS.md remains the instructional fallback.
Do not use the hook-trust bypass or unrestricted sandbox flags for setup.

Use `/mcp` for live MCP status and `/skills` to inspect the repository skills:
`kaimon-up`, `fromage-implement`, `thermo-nuclear-code-quality-review`.
The last two preserve Claude's explicit-invocation policy. Type
`$fromage-implement` for implementation: the prefix avoids collision with a
user-installed generic `implement` skill. Use `/agent` to inspect delegated
threads; it is not a static custom-agent inventory command.

Root `AGENTS.md` is automatically loaded. It requires reading the complete
`CLAUDE.md` and names conditional references explicitly. Codex reads at most one
instruction file per directory, preferring `AGENTS.override.md`, then
`AGENTS.md`, then configured fallbacks, from the Git root to the starting working
directory. Deeper instructions override earlier ones. Default combined size is
32 KiB; this bootstrap fits without increasing it. A personal override or a
smaller user limit can still shadow/truncate instructions; validate after setup.

## Kaimon and semantic search

### Connection and credentials

The repository defines one native Streamable HTTP MCP server, `kaimon`, at the
public loopback default `http://localhost:2828/mcp`. This is an already-running
service: there is no Codex child command, argument list, working directory or
stdio environment to translate. The original Claude connection is user-level,
not a repository `.mcp.json`. It uses Authorization authentication; the existing
Codex user configuration uses a header helper. Both were retained without copying
their values. No extra Qdrant MCP server is needed: Kaimon owns the search tools.

For a new machine, merge `.codex/kaimon.local.example.toml` into your user config,
or keep an existing working `http_headers_helper`. Supply `KAIMON_API_KEY` from
your secret manager. In an interactive Bash terminal, a non-echoing alternative is:

```sh
read -r -s -p 'Kaimon API key: ' KAIMON_API_KEY
export KAIMON_API_KEY
codex
unset KAIMON_API_KEY
```

Never paste the value into chat, a shell command argument, tracked TOML or a
transcript. `bearer_token_env_var` names an environment variable; its value is
not a TOML interpolation. For other header schemes use `env_http_headers` with
variable names. Ordinary TOML strings do not perform shell expansion. For stdio
servers, `env_vars` forwards named variables and `cwd` selects the child working
directory; neither is needed here.

An ignored `*.local.toml` file is **not automatically loaded by Codex**. The
template is an example to merge into user config, not a hidden configuration
layer. Project values outrank user values, so a nondefault port requires an
explicit CLI override when starting Codex:

```sh
KAIMON_PORT=3838 codex -c 'mcp_servers.kaimon.url="http://localhost:3838/mcp"'
```

`KAIMON_PORT` makes the shared startup hook check that same port. Adjust both
values together. Never override the URL to a remote service while retaining
local credentials without reviewing that destination.

### Service startup and health

Kaimon is installed outside Fromage. Its installed README documents Julia's
`app add Kaimon`, then the `kaimon` executable under `~/.julia/bin/`. If already
installed but missing from PATH, start it with:

```sh
"$HOME/.julia/bin/kaimon"
```

Use its setup UI to review security mode, API key, port and allowed projects.
Register this checkout in the user's Kaimon project/grep allowlists, never in
tracked configuration. A new Julia minor may need KaimonGate installed in that
minor's **global** environment; the Troubleshooting section of
`.claude/skills/kaimon-up/SKILL.md` describes the exact missing-ZMQ failure and
session-log diagnosis. Do not add KaimonGate to Fromage's dependencies.

The inspected Kaimon version supports managed Qdrant: `KAIMON_QDRANT_MANAGED`
is `auto`, `always` or `off`; default `auto` starts an installed service on
demand, while an existing service is reused. Install/enable managed Qdrant
through Kaimon's setup UI when needed. Do not start a second service on an
occupied port. This session found Qdrant already running; provisioning from an
empty machine was not tested. Its loopback default is port 6333. Ollama serves
embeddings on its usual loopback port 11434. Health checks:

```sh
curl --fail --max-time 3 http://localhost:6333/healthz
ollama list
codex mcp list
```

If Ollama is absent, install it outside the package and start `ollama serve`.
If the required model is absent, deliberately download it with
`ollama pull qwen3-embedding:0.6b`. Downloads and service provisioning are setup
operations, not validation steps, and were not performed during this migration.

Inside Codex, invoke `$kaimon-up`; its shared procedure in
`.claude/skills/kaimon-up/SKILL.md` lists the evidence each layer must show.
The startup hook only checks HTTP reachability; a 401 proves a listener exists,
not that credentials, MCP initialization, Julia or search work.

### Index lifecycle

The live `fromage` collection uses **qwen3-embedding:0.6b**. Local Kaimon search
configuration maps this checkout's absolute path to source, test, docs, examples
and benchmark directories; collection names are logical, stored paths are
machine-specific. Multiple clones sharing a collection can return another
checkout's paths. Confirm the path and live line before using any result.

Kaimon's user `search.json` records indexing configuration and embedding models;
`projects.json` records allowed projects/grep paths. Its private config includes
credentials. Qdrant storage, snapshots, service environment, logs and indexes
belong in Kaimon's user cache (managed storage is under `qdrant/storage`), not Git.
No such data is copied into this repository.

Reindexing (per file, and the full rebuild) follows CLAUDE.md §2, "Finding code",
with this checkout's root. Keep the embedding model consistent with the collection.

## Permissions and hooks

Project defaults are `workspace-write`, network disabled in shell sandbox,
and `on-request` approvals routed to Codex's automatic reviewer through
`approvals_reviewer = "auto_review"`. Eligible shell escalations and MCP approvals
are reviewed automatically, so routine local work does not require a human
approval for each operation. This matches the user's preferred auto mode; the
previous project setting `user` overrode the global `auto_review` preference.
Start a new Codex session to load the changed default. Automatic review can still
deny a request or fail; this setting is not unconditional approval, and AGENTS.md's
explicit authorization requirements for delivery operations still apply.
No writable roots or interpreter/Git/
GitHub allow rules are added. Native `.git`, `.codex` and `.agents` protections
remain in place. User/system policy and explicit CLI overrides can change the
effective configuration; the validator tests the repository defaults in isolation.

All 18 existing read-only Kaimon allowlist entries use per-tool `auto` or `approve`;
every other Kaimon tool defaults to `prompt`, routed through automatic review,
including eval, tests, session
management, editing, indexing and package mutation. Server-side Kaimon permissions
remain independent. MCP executes outside the shell filesystem/network sandbox:
read-only specialist roles also restrict Kaimon to the explicit read-only list.
Shell read-only mode does not itself prevent remote writes; investigator prompts
prohibit those. User-added MCP servers need their own review.

The Claude PR-merge allowance and eight user-local grants were intentionally not
copied. Codex rules prompt on Git push/tag/remote/reset/clean and GitHub merge,
release, workflow dispatch and API commands. Prefix rules govern escalation,
not every possible spelling, wrapper, API or in-sandbox command. They are a
second guard, not a universal release firewall; explicit authorization in
AGENTS.md and disabled sandbox networking remain necessary.

Both existing Bash hook scripts are reused directly. Official Codex 0.155.1
hooks normalize shell calls to `Bash` with `tool_input.command`, and accept the
same `hookSpecificOutput` SessionStart context and PreToolUse deny JSON. Thus
no input adapter or duplicated policy script is needed. Both have five-second
timeouts. The search hook is blocking, read-only and network-free; its exit code
is normally zero even for denial. The startup hook performs only a two-second
loopback GET and emits context. The search hook's shell wrapper runs
`prefer_kaimon_search.py`, which tokenises the command and denies only a search
that reads this repo's Julia code; it reads the payload's `cwd` when present and
falls back to the process working directory. Its scope and `# kaimon-ok` override
are exactly as in Claude; hook errors, timeouts and a missing `python3` fail open,
so the hook is not a security boundary. Review visibility with `/hooks`.

## Complete coverage matrix

Categories: **Native**, **Shared**, **Adapter**, **Manual**, **Unsupported**,
**Not migrated**. “Validated” means structural/native discovery or the specific
runtime evidence stated; it does not imply an end-to-end model task was run.

| Original | Purpose | Codex counterpart/category | Validation and limitation |
|---|---|---|---|
| `CLAUDE.md` | Complete operational rules | `AGENTS.md`, Shared + Adapter | Native prompt discovery; original hash unchanged; Codex explicit delivery authority overrides §6 |
| `CONTEXT.md`, `DECISIONS.md` | Domain and historical decisions | Shared required reads | Reachable; unchanged |
| `CIFS-SHARE-INVESTIGATION.md`, `WHY-FRAMES-FAIL.md`, `WHY-THE-SUITE-IS-SLOW.md` | Troubleshooting evidence | Shared conditional reads | Reachable; unchanged; no live-share experiment |
| `.claude/settings.json` | Permissions and hook wiring | `.codex/config.toml`, `hooks.json`, `rules/fromage.rules`, Native | TOML/JSON and native config/hook/rule parsing; 18-tool parity checked |
| `.claude/settings.local.json` | Private grants | Not migrated | JSON parsed and preserved; portable ignore added; personal permissions must be reviewed separately |
| `.claude/hooks/kaimon-session-start.sh` | Reachability context | Native SessionStart, Shared script | Syntax, mocked reachable/unreachable responses and native registration; trusted lifecycle not exercised |
| `.claude/hooks/prefer-kaimon-search.sh` | Semantic-search enforcement | Native PreToolUse/Bash, Shared script | Deny/allow JSON fixtures and native registration; requires hook trust |
| `.claude/agents/implementation-scout.md` | Calls/types/discovery | `.codex/agents/implementation-scout.toml`, Native + Shared prompt | Native role registration, reference and read-only checks |
| `.claude/agents/test-auditor.md` | Coverage/regression risks | `.codex/agents/test-auditor.toml`, Native + Shared prompt | Same; no full-suite execution by reviewer |
| `.claude/agents/docs-auditor.md` | Docs/CSV impact | `.codex/agents/docs-auditor.toml`, Native + Shared prompt | Same; current workflow exclusions override old prose |
| `.claude/agents/numerics-auditor.md` | Scientific correctness | `.codex/agents/numerics-auditor.toml`, Native + Shared prompt | Same; runtime experiments returned to parent |
| `.claude/agents/performance-auditor.md` | Allocations/inference/scaling | `.codex/agents/performance-auditor.toml`, Native + Shared prompt | Same; measurements delegated to parent to preserve read-only scope |
| `.claude/agents/julia-idiom-reviewer.md` | Julia invariants | `.codex/agents/julia-idiom-reviewer.toml`, Native + Shared prompt | Same; actual model delegation not part of discovery test |
| `.claude/skills/kaimon-up/SKILL.md` | Session/search bootstrap | `.agents/skills/kaimon-up/SKILL.md`, Adapter | Native discovery; live ping/collection/search/grep; owned REPL unavailable |
| `.claude/skills/implement/SKILL.md` | Test-first implementation/delivery | `.agents/skills/fromage-implement/`, Adapter | Native discovery, explicit invocation policy; generic skill fallback supplied |
| `.claude/skills/thermo-nuclear-code-quality-review/SKILL.md` | Strict structural review | `.agents/skills/thermo-nuclear-code-quality-review/`, Adapter | Native discovery, explicit invocation policy; no implied edit authority |
| No `.claude/commands/` | No repository custom commands | Native skills | No commands omitted; Claude slash/plugin names are not Codex commands |
| User-level Kaimon MCP definition; no `.mcp.json` | Authenticated HTTP tools | `.codex/config.toml` + local auth example, Native | Server listed and live calls succeeded using existing host credentials; clean-machine auth setup untested |
| User-level Kaimon config/search/projects | Allowed paths/index setup | Manual setup above | Filtered metadata checked; no private values copied |
| Qdrant/Ollama | Embeddings/vector and lexical search | Shared Kaimon tools | Live health/model/semantic query + live-line confirmation; no rebuild |
| User `mattpocock-skills` plugin | General engineering workflows | Existing Codex engineering skills + wrapper fallbacks, Manual | Available locally; not a repository dependency; plugin installer not run |
| User Claude `codex` plugin | Delegate from Claude to Codex | Not migrated | Already running Codex; recursive delegation is unnecessary |
| `docs/agents/domain.md`, `issue-tracker.md`, `triage-labels.md` | Engineering skill configuration | Shared | Existing resources unchanged; provisioning examples never run |
| `README.md`, package/test/docs/benchmark TOMLs | Setup/environments | Shared | Julia 1.13 used; versions/dependencies unchanged |
| `test/runtests.jl`, `quality.jl`, `jet.jl`, fixtures/harness | Tests and invariants | Shared commands | Full threaded suite run separately; entry points unchanged |
| `docs/make.jl`, `docs/src/` | Build and deploy | Shared + `build-local.jl` Adapter | Adapter rejects unexpected AST shape and excludes deploydocs before evaluation; user docs unchanged |
| `RELEASING.md` | Release/recovery | Shared mandatory read + explicit authorization | Hash preserved; no recovery executed |
| `.github/workflows/Test.yml`, `TestOnPRs.yml`, `ReusableTest.yml` | Test gates | Shared | YAML parsed, hashes unchanged; no workflow dispatch |
| `.github/workflows/AutoRelease.yml`, `Docs.yml`, `DocPreviewCleanup.yml` | Release/deploy/preview cleanup | Shared safety-critical reference | Parsed/inspected only; no execution |
| `.github/workflows/Format.yml`, `Lint.yml` | Runic/link checking | Shared | Parsed/unchanged; local adapter Runic check; no remote link sweep |
| `.github/workflows/PersistentTasks.yml`, `ToleranceResiduals.yml` | Separate specialized checks | Shared | Parsed/unchanged; not run for integration |
| `.github/workflows/CacheCleanup.yml`, `.github/scripts/cache-cleanup.sh` | Remote cache cleanup | Shared reference | YAML/Bash syntax only; even dry-run remote queries not executed |
| `.github/workflows/CompatHelper.yml`, `.github/dependabot.yml` | Dependency update automation | Shared | Parsed/unchanged; never invoked |
| `.gitignore`, `.lychee.toml`, `codecov.yml`, `.copier-answers.yml` | Generated files/tool metadata | Shared; additive ignores only | Local files ignored and integration files visible; other metadata unchanged |
| `simulation/` | Separate research package | Shared boundary in AGENTS.md | No package/CI change or simulation test needed |

There are no separate repository architecture, CI, release, security or debugging
agent definitions to port. Those concerns live in the shared instructions,
specialist prompts, generic installed skills and Kaimon tools. Claude-specific
tool-name allowlists cannot be copied as Codex agent metadata: native read-only
sandbox plus MCP enabled-tools lists preserve the restriction as closely as the
host supports. General shell access is still a capability, not a proof of purity.

## Validation and maintenance

Run from the root (Python 3.11+, PyYAML, Codex, Bash, jq and Git required; none is
a Fromage runtime dependency):

```sh
python3 docs/agents/validate-codex.py
julia --project=docs --startup-file=no docs/agents/build-local.jl --check
git diff --check
```

The validator parses structured config/frontmatter, checks every original role
and skill has a reachable native wrapper, checks the read-only MCP list against
Claude settings, exercises harmless hook payloads, and asks Codex's own rules
engine about release commands **without executing those commands**. It starts
a temporary app-server for `config/read`, `skills/list`, and `hooks/list`, then
constructs a local debug prompt with hooks and MCP disabled. It never calls a
model, initializes an MCP server, trusts a hook persistently or writes user
configuration. Temporary project trust is only for validating the candidate
config, not evidence that your normal session is trusted. No effective secrets
or raw prompt/config dumps are printed.

Native agent registration is explicit in `[agents.<name>]` as well as using the
supported `.codex/agents/*.toml` files, making roles inspectable in config/read.
Each role's `[mcp_servers.kaimon]` table must include `url` alongside
`enabled_tools`: Codex 0.155.1 deserializes the role before merging configuration
layers, so an allowlist alone produces `invalid transport`. Keep the role URLs
in sync with `.codex/config.toml` when changing the configured endpoint; credentials
remain in user configuration. The validator checks URL parity and captures
app-server stderr, where malformed-role errors are reported even when metadata
requests succeed.
There is no custom-agent-list CLI/RPC in this installed version. The validator
checks declarations, resolved file references and malformed-role startup warnings;
actual delegated model execution remains a
separate interactive smoke test. Request an implementation scout to find the
share retry function and return confirmed evidence without edits.

`codex --strict-config` works for the app-server; it is **not supported for
`codex mcp`** in 0.155.1. Use `codex mcp list`, `/mcp`, `/skills`, `/hooks` and the
validator instead. `codex debug prompt-input` constructs a session and can run
startup hooks unless disabled; use the validator's safe path rather than dumping
a potentially sensitive effective prompt. `codex doctor --help` describes local
diagnostics; review output locally before sharing it.

Julia suites run as CLAUDE.md §2, "Tests", describes. Documentation-only local build after docs dependencies are installed:

```sh
julia --project=docs docs/agents/build-local.jl
```

The adapter reads the existing `docs/make.jl`, validates its five-expression
shape before evaluating anything, and evaluates only the three imports and
`makedocs`. It fails visibly if that shape changes. It does not evaluate
`deploydocs`; no release credentials are required. Vitepress may need its
existing Node/npm tooling and cached packages. Generated `docs/build` is ignored.
The shape check detects drift, not arbitrary side effects in future build
arguments or imported dependencies; changes to those still require review.

### Migration record

The original migration (commits `c6a7c3c`..`2b78ee4`, 2026-09-22) recorded its
full validation log here: CLI versions, the protocol-schema probe, the
first threaded suite run and the checks deliberately not run (trusted hook
lifecycle, delegated model turns, clean-machine provisioning). It is in git
history; `validate-codex.py` is the living check.

### Synchronization strategy

Both agents maintain the repo, and `CLAUDE.md` plus `.claude/` are the single
source: a shared rule, agent prompt or skill changes there, whichever agent makes
the change. Codex wrappers read the original complete role/skill prompt and add
only path, tool-name and authorization adaptations. AGENTS.md repeats only
bootstrap-critical rules and requires the complete operational reference. All
domain, design, troubleshooting, issue-tracker and release documents are shared.

After changing a Claude skill/agent name or adding one, update its native wrapper
and run the validator: it fails on missing counterparts, wrong names/policies,
broken references, allowlist drift or a release filter that stops ignoring agent
configuration. After changing operational rules, review AGENTS.md's critical
summary and the wrappers for semantic agreement — the validator checks
structure, not meaning. Generic engineering skills are installed per user
(`~/.agents/skills`), not vendored here. Descriptions
appear both in native role files and registration tables for discoverability;
keep these brief copies synchronized. No generator rewrites Claude files.

### Known limits and follow-up

- Project trust and hook trust require deliberate local setup. Validation does
  not grant either persistently; check `/hooks` before relying on enforcement.
- Claude and Codex permission schemas differ. Prefix rules are not a complete
  command firewall; native sandbox, per-tool approvals and explicit instruction
  boundaries are used together. No broad allow rule is introduced.
- User-level plugins, model choices, extra MCP servers and private grants are
  not portable repository configuration. Install optional skills intentionally;
  wrappers supply core fallbacks. Existing Claude plugin behavior stays intact.
- Original prompts contain historical paths, figures and test lists. Wrappers
  resolve paths dynamically and require current runtime/workflow evidence.
- Local service provisioning, clean-machine authentication and actual delegated
  model behavior were not simulated by a configuration parser. Re-run the live
  Kaimon checks on each machine.
- Hook scripts need Bash, curl, jq and Python 3. Native Windows users need those available
  (for example through Git Bash) or a WSL setup. Windows hook execution was not
  tested; without those dependencies, use the disclosed manual bootstrap/search
  fallback and do not claim deterministic enforcement.

## Sources consulted

Installed CLI help: `codex --version`, `--help`, `features list`, `mcp --help`,
`mcp list --help`, `debug --help`, `debug prompt-input --help`,
`app-server --help`, `app-server generate-json-schema --help`,
`execpolicy check --help`; generated app-server protocol schemas from 0.155.1.
Claude `--version`, `--help`, `agents --help` were inspected; its `agents` command
lists sessions, not static specialist definitions.

Official sources (consulted 2026-09-22):

- [AGENTS.md discovery](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
- [Configuration and trust](https://learn.chatgpt.com/docs/config-file/config-basic)
- [Configuration schema](https://developers.openai.com/codex/config-schema.json)
- [MCP transport, environment and approvals](https://learn.chatgpt.com/docs/extend/mcp)
- [Native skills](https://learn.chatgpt.com/docs/build-skills)
- [Native subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents)
- [Hooks and blocking semantics](https://learn.chatgpt.com/docs/hooks)
- [Rules and shell-wrapper limitations](https://learn.chatgpt.com/docs/agent-configuration/rules)
- [0.155.1 role loader](https://github.com/openai/codex/blob/rust-v0.155.1/codex-rs/agent-roles/src/loader.rs)
- [0.155.1 prompt diagnostics](https://github.com/openai/codex/blob/rust-v0.155.1/codex-rs/core/src/prompt_debug.rs)

Kaimon operational details were checked against its installed README,
`qdrant_server.jl`, `qdrant_client.jl`, filtered local search configuration and
live tools; private configuration values were not copied.
