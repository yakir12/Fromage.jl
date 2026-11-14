# Which General-registry packages cover the server, queue, progress and front end

Research for #441 (part of the map #439). Looked up on 2026-11-14 against the General registry,
each package's repository and shipped docs, and by running the candidates on Julia 1.13.3.
Nothing here was taken from memory: every version, date and count below was read or measured that
day, and the section "Not verified" lists what was not.

## Answer in one paragraph

Oxygen is confirmed as the server, and the whole web stack is light: **Oxygen + HypertextLiteral
add 11 packages and no binary to Fromage's 283**. The queue, the registry, the live status and the
progress capture need **no further package** — a `Channel`, a JSON file (JSON.jl arrives with
Oxygen), htmx polling or server-sent events (both already in Oxygen/HTTP.jl), and a custom
`ProgressMeter.AbstractProgress` cover them. The front end is server-rendered HTML with one vendored
JavaScript file (htmx), not a Julia UI framework. **CairoMakie is the only heavy item: 70 packages
on its own**, six times the rest put together, and it is what the package-boundary decision
should weigh.

## Recommendation per need

| Need | Recommendation | Adds to Fromage | Runner-up | Rejected |
|---|---|---|---|---|
| HTTP server and routing | **Oxygen.jl 1.11.0**, started with `metrics = false` | 9 packages, 0 JLL | HTTP.jl 2.16 alone (4 packages) | Genie (32), Mux (stuck on HTTP 1.x) |
| One-at-a-time queue | **No package**: a `Channel` and one consumer task | 0 | — | JobSchedulers (24, and downgrades a dep) |
| Persistent registry | **JSON.jl 1.13** file per job (already there through Oxygen) | 0 beyond Oxygen | SQLite.jl 1.11 (4 packages, 1 JLL) | JSON3 (downgrades CSV) |
| Live status in the browser | **htmx polling** of an HTML fragment; SSE where a page wants push | 0 (one vendored `.js`) | SSE through `HTTP.sse_stream` | websockets (two-way channel for one-way data) |
| Progress capture | **Custom `AbstractProgress` passed to `ProgressMeter.progress_map`** | 0 | ProgressLogging.jl (1 package) | parsing the terminal bar out of `output=io` |
| Front end | **HypertextLiteral.jl 1.0.0 + htmx 2.0.11**, plain CSS for the split pane | 2 packages + one `.js` | HypertextTemplates.jl (2), Mustache.jl (1) | Bonito (19, 2 JLL), Genie/Stipple (40) |
| PDF plots | **CairoMakie 0.15.17** (as asked) | 70 packages, 8 JLL, 4 existing versions moved | — | — |

Whole recommended set, resolved together: **+78 packages (8 JLL), 283 → 361**.

## How dependency weight was measured

A scratch environment `Pkg.develop`ed this worktree (Fromage 0.9.7) on Julia 1.13.3 and resolved
to **283 packages, 115 of them JLLs**. Each candidate was then `Pkg.add`ed to a copy of that
environment and the two manifests were compared. "Adds" is the number of manifest entries that
appear; "moved" lists entries whose resolved version changed. Standard libraries that were not
already in the manifest count as one each (it is how `Test` shows up below).

| Candidate | Version resolved | Adds | of which JLL | Existing versions moved | New entries |
|---|---|---|---|---|---|
| Oxygen | 1.11.0 | 9 | 0 | none | EnumX, HTTP, JSON, MIMEs, Oxygen, Reseau, StructTypes, StructUtils, URIs |
| HTTP | 2.16.0 | 4 | 0 | none | EnumX, HTTP, Reseau, URIs |
| Genie | 6.4.1 | 32 | 2 | none | includes Revise, JuliaFormatter, JuliaInterpreter, Nettle_jll, GMP_jll, YAML, EzXML |
| Mux | 1.0.2 | 17 | 1 | none | resolves **HTTP 1.11.1**, plus MbedTLS, OpenSSL |
| Bonito | 5.3.0 | 19 | 2 | none | includes Deno_jll, MbedTLS_jll, HTTP, Hyperscript, MsgPack, Observables, CommonMark |
| BonitoWidgets | 0.1.4 | 20 | 2 | none | Bonito plus itself |
| Stipple / StippleUI | 1.2.4 / 1.1.0 | 40 / 41 | 2 | none | Genie plus GenieSession, Observables, … |
| HypertextLiteral | 1.0.0 | 2 | 0 | none | HypertextLiteral, Tricks |
| HypertextTemplates | 2.2.4 | 2 | 0 | none | — |
| Hyperscript | 0.0.5 | 2 | 0 | none | Hyperscript, Test |
| Mustache | 1.1.0 | 1 | 0 | none | Mustache |
| OteraEngine | 1.1.3 | 1 | 0 | none | OteraEngine |
| JSON | 1.13.4 | 2 | 0 | none | JSON, StructUtils |
| JSON3 | 1.14.4 | 5 | 0 | **CSV 1.3.0 → 0.10.17, Parsers 3.0.6 → 2.8.11, InlineStrings 2.0.1 → 1.4.6** | — |
| SQLite | 1.11.0 | 4 | 1 | none | SQLite, SQLite_jll, DBInterface, WeakRefStrings |
| JobSchedulers | 1.0.1 | 24 | 2 | OrderedCollections 2.0.3 → 1.8.2 | includes JLD2, Term, TreeSitter, Pipelines |
| ProgressLogging | 0.1.6 | 1 | 0 | none | ProgressLogging |
| TerminalLoggers | 0.1.8 | 4 | 0 | none | + ProgressLogging, AbstractTrees, LeftChildRightSiblingTrees |
| CairoMakie | 0.15.17 | 70 | 8 | GeometryBasics 0.4.2 → 0.5.13, StructArrays 0.6.21 → 0.7.4, EarCut_jll 3.2.3 → 2.2.4, FreeType2_jll 2.15.0 → 2.14.3 | Makie 0.24.17 and its tree |
| WGLMakie | 0.13.17 | 81 | 9 | as CairoMakie, less FreeType2_jll | Makie + Bonito |
| **Oxygen + HypertextLiteral + CairoMakie** | | **78** | **8** | as CairoMakie | |
| Oxygen + SQLite + HypertextLiteral + CairoMakie | | 82 | 9 | as CairoMakie | |
| Bonito + CairoMakie | | 85 | 10 | as CairoMakie | |

Overlap that keeps the numbers small: Oxygen's own dependencies include `DataStructures`,
`LRUCache` and `RelocatableFolders`, which Fromage already has in `[deps]`; Cairo, HarfBuzz,
Fontconfig and Pixman are already in Fromage's tree through `FFMPEG`, which is why CairoMakie adds
only 8 binaries.

## Maintenance and health

Read from the GitHub API on 2026-11-14. "Open issues" excludes pull requests.

| Package | Latest release | Last push | Open issues | Julia compat | Note |
|---|---|---|---|---|---|
| Oxygen.jl | 1.11.0, 2026-08-28 | 2026-10-22 | 9 | 1.11+ | 506 stars; eight releases from 2025-09 to 2026-08 |
| HTTP.jl | 2.16.0, 2026-11-13 | 2026-11-13 | 0 | 1.10+ | 2.0.0 was 2026-05-28; 46 releases in the 2.x line since |
| Reseau.jl (HTTP 2's transport) | — | 2026-11-12 | 12 | — | "Pure-Julia IO primitives", 29 stars |
| Genie.jl | 6.4.1, 2026-10-15 | 2026-10-15 | 108 | — | |
| Mux.jl | 1.0.2 in the registry; last GitHub release 1.0.1, 2022-10-14 | 2024-06-28 | 16 | — | dormant |
| Bonito.jl | 5.3.0, 2026-11-03 | 2026-11-03 | 70 | 1.11+ | 331 stars; requires HTTP 2.4+ |
| HypertextLiteral.jl | 1.0.0, 2026-01-16 | 2026-05-01 | 7 | — | JuliaPluto org, ISC licence |
| HypertextTemplates.jl | 2.2.4, 2026-03-20 | 2026-11-13 | 12 incl. PRs | 1.6+ | 8 stars, one maintainer |
| Hyperscript.jl | 0.0.5, 2023-12-06 | 2026-06-11 | 9 | — | never left 0.0.x |
| Mustache.jl | 1.1.0, 2026-09-23 | 2026-09-23 | 10 | — | |
| OteraEngine.jl | 1.1.3, 2025-05-11 | 2026-03-12 | 0 | — | 28 stars |
| JSON.jl | 1.13.4, 2026-10-30 | 2026-10-30 | 1 | — | |
| JSON3.jl | 1.14.4, 2026-10-27 | 2026-10-27 | 2 | — | |
| SQLite.jl | 1.11.0, 2026-10-30 | 2026-10-30 | 8 | 1.9+ | |
| JobSchedulers.jl | 1.0.1, 2026-07-04 | 2026-07-04 | 1 | — | 63 stars |
| ProgressMeter.jl (already a dep) | 1.13.0, 2026-10-20 | 2026-10-21 | 49 | 1.10+ | |
| ProgressLogging.jl | 0.1.6, 2025-11-22 | 2025-11-22 | 12 | 0.7+ | still 0.1.x |
| TerminalLoggers.jl | 0.1.8, 2026-08-03 | 2026-08-03 | 10 | — | |
| Makie.jl (CairoMakie) | 0.24.17, 2026-10-31 | 2026-11-14 | 806 | — | 2836 stars |
| Malt.jl (see #442) | 1.5.0, 2026-10-24 | 2026-10-24 | 29 incl. PRs | 1.6+ | deps are stdlibs + RelocatableFolders |
| htmx (JavaScript, not a Julia package) | 2.0.11 and 4.0.1, both 2026-11-01 | 2026-11-13 | — | — | Zero-Clause BSD |

## 1. HTTP server and routing — Oxygen, confirmed, with four things to know

Oxygen 1.11.0 describes itself as "a micro-framework built on top of the HTTP.jl library". Its
README lists what the site needs: routing with typed path parameters, `formdata(req)` for HTML
forms, `html(...)` responses, middleware, static file mounting, "Websockets, Streaming, and
Server-Sent Events", `@repeat` tasks, and package extensions for CairoMakie (`png`, `svg`, `pdf`
response helpers taking a `Figure`), Bonito, Mustache and OteraEngine.

Run here on Julia 1.13.3 with Oxygen 1.11.0 and HTTP 2.16.0, on `127.0.0.1`:

- a `@get` returning HypertextLiteral output through `html(...)` — worked, and the interpolated
  `<script>` came back escaped;
- a `@post` reading a urlencoded form with `formdata(req)` — returned `{"mode":"expert","target_width":"2"}`;
- an `@stream` handler writing `format_sse_message(...)` — three events arrived, spaced in time;
- a plain `@get` returning `HTTP.sse_stream(200) do stream … end` — three events arrived, spaced
  in time, with their ids.

The four things:

1. **Oxygen has been on HTTP.jl 2.x for one release.** HTTP.jl 2.0.0 (2026-05-28) is a breaking
   release built on a new pure-Julia transport, Reseau.jl; Oxygen moved to it in PR #302 (2026-08-21) and
   1.11.0 a week later is the only release since. HTTP.jl has shipped 46 releases in the 2.x line
   in under six months. Everything works today, and the base is moving fast: pin `HTTP` in
   `[compat]` and expect to bump it deliberately.
2. **Oxygen's default metrics middleware breaks ranged file responses.** With defaults,
   `HTTP.servefile(req, path)` answered a `Range: bytes=100-199` request with **500**
   (`ArgumentError: body is closed`); the same handler under `serve(; metrics = false)` answered
   **206** with 100 bytes, as did plain `HTTP.serve!`. The cause is in Oxygen's
   `src/core.jl`, `MetricsMiddleware`: for every response whose status is not 200 it calls
   `text(response)` to record the body, which drains a streaming body before HTTP.jl sends it.
   A 206 is not a 200. Browsers seek in `<video>` with range requests, so the diagnostic video
   needs this. `docs = true` alone did not break it. No issue for it was found on the Oxygen
   tracker.
3. **`staticfiles` and `dynamicfiles` are not for the results.** `staticfiles` loads every file
   into memory at start-up (README), and `dynamicfiles` re-reads the whole file per request
   (`src/utilities/render.jl`, `read(filepath)`). They suit the site's own CSS and the htmx file.
   Diagnostic videos and csv downloads should go through `HTTP.servefile`, which streams from disk
   and answers `Range` and `If-Modified-Since` (HTTP.jl server guide, "Static Files").
4. **Give the server an interactive thread.** HTTP.jl's README: server tasks run "on Julia's
   `:interactive` thread pool so they can remain responsive when the default pool is busy. Start
   production servers with at least one interactive thread, for example `julia --threads=4,1`",
   otherwise "non-yielding compute tasks can delay HTTP work". Fromage's tracking saturates the
   default pool through OhMyThreads, so this matters if a job ever runs in the server's process.
   Measured with `--threads=4,1` and four spinning tasks on the default pool: a request still
   returned in 0.05 s. The control without an interactive thread was not run.

HTTP.jl 2.16 on its own is a real alternative at 4 packages instead of 9: it has
`HTTP.Handlers.Router`, `HTTP.fileserver` / `servefile` / `servecontent`, `HTTP.sse_stream`,
and websockets. What Oxygen adds for its 5 extra packages (JSON, StructUtils,
StructTypes, MIMEs, itself) is typed path parameters, `formdata`, the response helpers, middleware
at router and route level, and repeat tasks — and JSON.jl would be wanted for the registry anyway.

Genie is a full MVC framework that brings Revise, JuliaFormatter and a session store (32 packages,
108 open issues); nothing in the map needs it. Mux was last pushed to in June 2024 and resolves
HTTP 1.11.1, so it cannot share an environment with Oxygen 1.11 or Bonito 5, both of which
require HTTP 2.4+.

## 2. One-at-a-time queue and persistent registry — no package needed

**Queue.** "One job at a time, in order of submission" is a `Channel` of job ids with a single
consumer task, both in Base. No registry package does less work than that.

JobSchedulers.jl 1.0.1 is the only general job scheduler found in the registry ("inspired by
Slurm/PBS and Crontab": dependencies between jobs, cpu and memory accounting, cron schedules,
"automatic backup and reload"). It costs 24 packages including JLD2, Term and TreeSitter, moves
`OrderedCollections` down from 2.0.3 to 1.8.2, and solves a larger problem than a single-file
queue.

**Registry.** Ten users and one running job is a handful of small records. Candidates, cheapest
first:

- **A JSON file per job, written with JSON.jl 1.13** — free once Oxygen is in (JSON and
  StructUtils are in Oxygen's 9). One file per job means a status update rewrites one small file,
  and writing to a temporary name followed by `mv` keeps a crash from leaving half a record.
- stdlib `TOML` — zero packages either way, and equally adequate.
- **SQLite.jl 1.11.0** — 4 packages, 1 JLL, healthy (released 2026-10-30, 8 open issues). Worth
  it only if the registry needs queries or several writers; nothing in the map asks for either.
- JSON3.jl — avoid. Adding it pulled **CSV from 1.3.0 down to 0.10.17** and Parsers from 3 to 2.
  Fromage's compat permits CSV 0.10, so it resolves, and it is still a downgrade of a direct
  dependency for no gain over JSON.jl 1.x.

## 3. Live status — polling first; SSE is there when wanted; websockets are not needed

All three transports exist with no extra Julia package:

| Transport | Server side | Browser side | State |
|---|---|---|---|
| Polling | an ordinary `@get` returning an HTML fragment | htmx: `hx-get="/jobs/42/status" hx-trigger="every 2s"`; the server answers status **286** to stop the polling (htmx docs) | nothing held open |
| Server-sent events | `HTTP.sse_stream(200) do stream; write(stream, HTTP.SSEEvent(data; event, id)); end`, or Oxygen's `@stream` + `format_sse_message` — both verified above | `EventSource`, or htmx's SSE extension 2.2.4: `hx-ext="sse" sse-connect="/events" sse-swap="progress"` | one task per open page |
| Websockets | Oxygen `@websocket`, `HTTP.WebSockets` | script | one task per open page; two-way |

The recommendation is polling for the registry table and for a job's status page: it survives a
server restart and a closed laptop without reconnection logic, every request is a plain route that
can be opened in a browser to debug, and at ten users it is a few requests per second at most.
SSE is the upgrade for a page that should move smoothly, and costs nothing to add later because
the fragment it pushes is the fragment polling fetches. Status flows one way, so websockets buy
nothing here. Oxygen's tracker has two open websocket issues from 2024 (#200 payload limit, #201
"Websocket disconnect errors instead of handling gracefully").

## 4. Capturing progress from `@showprogress` code

The call sites today: `src/main.jl:106` ("Building rectifications") and `:206` ("Building runs"),
`src/gateway.jl:165` and `:205`, `src/VerifyRuns/VerifyRuns.jl:68`,
`src/VerifyRectifications/VerifyRectifications.jl:67`. Every one is
`@showprogress desc = … [enabled = …] tmap(f, xs)`.

What ProgressMeter 1.13.0 does with that (read in its source, `showprogress_map` and
`progress_map`): the macro rewrites the call to
`progress_map(f, xs; mapfun = tmap, progress = Progress(n, <the macro's keywords>))`.
`progress_map` runs `mapfun`, puts a token on a channel after each call of `f`, and a display task
calls `next!(progress)` per token. OhMyThreads supplies the `ncalls` methods that make `tmap`
count as map-like (its `ProgressMeterExt`). Two consequences were tested:

- **(A) `output = io`.** The macro's keywords reach `Progress`, so
  `@showprogress desc = "…" output = io tmap(…)` redirects the bar. Verified: an `IOBuffer`
  received 703 bytes of frames ending in
  `"Building runs 100%|████…| Time: 0:00:01\e[K\n"`. It is the terminal rendering — carriage
  returns, ANSI erase codes, a percentage rounded to an integer and an ETA as text — so using it
  means parsing a display format.
- **(B) A custom `AbstractProgress`.** `ProgressMeter.AbstractProgress` is the abstract supertype of
  `Progress`, and `progress_map` calls nothing on its `progress` argument except `next!`. Verified:
  a 3-field struct `<: ProgressMeter.AbstractProgress` with one `ProgressMeter.next!` method, passed
  as `progress_map(f, 1:40; mapfun = tmap, progress = reporter)` on 4 threads, received exactly
  40 ticks and returned the right result. The reporter can then do anything with a tick — update a
  field the server reads, or write a line for another process to read. The cost is that the call
  sites stop using the macro and call `progress_map` directly (which is what the macro expands to),
  because `@showprogress` always constructs a `Progress` itself.

**ProgressLogging.jl 0.1.6** is the other established route: progress becomes log records at
`ProgressLevel` and any `AbstractLogger` can collect them. It is one package with stdlib-only
dependencies. Tested: `@progress tmap(…)` is rejected at macro-expansion time ("`@progress`
requires a for loop … or array comprehension"), so each site would become `@withprogress` around
the `tmap` with a hand-kept atomic counter and `@logprogress k/n`; written that way, a 10-line
custom logger collected 11 records for 10 items. A record carries a fraction and a name, no count
and no ETA. And ProgressLogging draws nothing itself, so the command-line bar that exists today
would need TerminalLoggers (4 packages) to keep existing. Two glue packages are in the registry
and were not evaluated beyond their entries: ProgressMeterLogging.jl (a single 0.1.0 release) and
ProgressTMap.jl (1.0.1, built on ProgressLogging).

Recommendation: **(B)**. No new dependency, the command line keeps its bar by passing a real
`Progress`, and the site passes a reporter — chosen by type, which is the dispatch pattern this
repo already asks for.

Three things no package changes:

- **Time remaining** is arithmetic on (done, total, elapsed): ProgressMeter's own ETA is
  `elapsed * (n - start) / (counter - start) - elapsed`. A reporter that records counts gives the
  site the same number.
- **Granularity.** A tick is one rectification, one run, or one file. A job of three long runs
  moves in thirds, however the ticks are transported. Finer progress means reporting from inside
  `track_run`, which is a change to Fromage and not a package choice.
- **The process boundary.** If #442 concludes that a job runs in a child process, progress has to
  cross it. (B) still fits — the reporter's `next!` writes a line to a pipe or a file — and (A) is
  what the child's stderr carries untouched.

## 5. Front end — server-rendered HTML with htmx

The page is a folder picker, a settings form with an easy and an expert mode, a table of jobs and
a results page with downloads. That is forms and tables, which HTML does natively:

- **Markup: HypertextLiteral.jl 1.0.0** (2 packages). `@htl("<p>$x</p>")` interpolates Julia values
  into HTML and escapes them by context; verified above. It reached 1.0.0 in January 2026 and is
  maintained in the JuliaPluto organisation.
- **Interactivity: htmx 2.0.11**, one dependency-free JavaScript file of about 16 kB gzipped,
  Zero-Clause BSD. It is not a Julia dependency: the file is downloaded once, committed, and
  served from the site's own static folder — the htmx docs describe exactly this and advise
  against relying on a CDN in production. It gives form submission without a page reload, the
  polling and SSE attributes in section 3, and `hx-swap-oob` for updating a second region (the
  preview pane) from the same response. htmx 4.0 exists (4.0.1, 2026-11-01); htmx.org's quick
  start still installs 2.0.11 and says 4.0 will not be tagged `latest` on npm until some time
  in 2027, so 2.x is the line to pin.
- **Split pane and the two modes: CSS**, no package. A two-column `grid` is the split pane; the
  expert fields sit in a `<details>` element or behind a class toggle.

Alternatives, in order of closeness:

- **HypertextTemplates.jl 2.2.4** (2 packages): elements as macros, a component system with
  slots, escaping by default, streaming render. More structure than HypertextLiteral for a larger
  site; 8 stars and one maintainer, though actively pushed.
- **Mustache.jl 1.1.0** (1 package) and **OteraEngine.jl 1.1.3** (1 package): templates kept in
  separate files, with Oxygen extensions for both. Reasonable if the HTML should live outside
  Julia source. OteraEngine's last release is May 2025.
- **Bonito.jl 5.3.0** (19 packages, 2 JLLs including Deno): a reactive UI in Julia — `Observable`s
  bound to widgets over a websocket, with `TextField`, `NumberInput`, `Dropdown`, `Checkbox`,
  `Slider`, `FileInput`, `Table`, `Card`, `Grid`, `Row`, `Col`, and server pieces of its own
  (`Server`, `route!`, `ProtectedRoute`, `FolderServer`). It is a different architecture rather
  than an add-on: the page's state lives in a Julia session per browser tab. That suits a live
  dashboard and fits a job registry less well, where the state that matters is on disk and must
  outlive every browser. It would largely replace Oxygen, and carries 70 open issues.
- **Genie + Stipple/StippleUI** (40–41 packages): the richest ready-made widgets (Vue and Quasar),
  at more than three times the weight of the recommended web stack.
- Hyperscript.jl is still 0.0.5 from 2023; it arrives as a Bonito dependency and is not worth
  choosing directly.

## 6. CairoMakie, since the results page wants PDF plots

- **Weight: +70 packages, 8 JLLs** (CairoMakie 0.15.17, Makie 0.24.17). That is a quarter again
  on top of Fromage's 283, against +11 for the entire web stack.
- **It moves four versions Fromage resolves today**: GeometryBasics 0.4.2 → 0.5.13 and
  StructArrays 0.6.21 → 0.7.4 (both reach Fromage through `FreeTypeAbstraction`), EarCut_jll
  3.2.3 → 2.2.4, and **FreeType2_jll 2.15.0 → 2.14.3**, which sits under `FreeTypeAbstraction` and
  `FFMPEG_jll` — the text drawn on diagnostic videos. Nothing was run against those moved
  versions; the diagnostic-video tests are the ones to watch.
- **It works on Julia 1.13.3**: in a scratch environment, `using CairoMakie` took 3.4 s once
  precompiled, and a figure with a `DataAspect` axis, a line, a marker and an arrow saved as a
  7 kB file starting `%PDF-` in 9.6 s (first-call compilation included).
- Oxygen's `CairoMakieExt` turns a `Figure` into a response with `pdf(fig)`; the same `Figure`
  can be `save`d to disk for the download link.

## What bears on the package-boundary decision

- The web stack proper (Oxygen, HypertextLiteral, and through them HTTP, JSON) is **11 pure-Julia
  packages, no binary, no existing version moved**.
- CairoMakie is **70 packages, 8 binaries, 4 existing versions moved** — including a FreeType
  downgrade under code Fromage already ships.
- Julia's package extensions (`[weakdeps]`) are how Oxygen itself keeps CairoMakie optional.
- Whether that argues for a submodule, an extension or a separate package is the boundary ticket's
  call; these are its inputs.

## Not verified

- **No candidate was run against Fromage's own code.** Every test above used toy handlers and
  toy workloads; `Fromage.main` was never called through any of it.
- **The moved versions under CairoMakie** (GeometryBasics, StructArrays, EarCut_jll,
  FreeType2_jll) were resolved, not exercised. Fromage's suite was not run with them.
- **Precompile time for CairoMakie** was not timed separately; installing and precompiling it took
  several minutes of wall clock on this machine, load afterwards 3.4 s.
- **The interactive-thread claim** has only its positive half measured (responsive with
  `--threads=4,1`); the degraded case without one is HTTP.jl's statement, not a measurement here.
- **The Oxygen metrics/range failure** was reproduced on Oxygen 1.11.0 + HTTP 2.16.0 only, and
  not reported upstream.
- **Bonito, Genie, Stipple, Mux, JobSchedulers, HypertextTemplates, Mustache, OteraEngine and
  SQLite were not run** — resolved and read only. In particular Bonito's behaviour when a browser
  reconnects or a session is lost is taken from its docs' mention of a connection indicator, not
  tested.
- **htmx was not run in a browser.** Its attributes and version guidance are quoted from htmx.org.
- **Websockets were not exercised** in Oxygen; only SSE and plain requests were.
- **JuliaHub was not consulted**; health figures come from the GitHub API, versions and
  dependency counts from the General registry as resolved by Pkg.
- ProgressMeterLogging.jl and ProgressTMap.jl were found in the registry and not evaluated.
- `progress_map` calling only `next!` on its `progress` argument is how ProgressMeter 1.13.0 is
  written, not a documented contract; a test should pin it if (B) is adopted.

## Side effect of this research

Resolving the candidates refreshed the General registry in the shared `~/.julia` depot (it had
last been updated on 2026-10-28). Everything else — environments, downloaded packages, compiled
caches — went to a scratch depot outside the repository.

## Sources

- General registry, as resolved by Pkg on Julia 1.13.3 on 2026-11-14 (versions, compat, counts).
- Oxygen.jl 1.11.0: `README.md`, `Project.toml`, `src/core.jl` (`MetricsMiddleware`),
  `src/utilities/render.jl`, `src/utilities/misc.jl` (`format_sse_message`), `demo/ssedemo.jl`,
  `ext/CairoMakieExt.jl` — <https://github.com/OxygenFramework/Oxygen.jl>
- HTTP.jl 2.13–2.16: `README.md`, `docs/src/guides/server.md` ("Static Files", "Server-Sent
  Events"), `docs/src/guides/migration-1x.md` — <https://github.com/JuliaWeb/HTTP.jl>
- ProgressMeter.jl 1.13.0: `src/ProgressMeter.jl` (`ProgressCore`, `Progress`, `showprogress_map`,
  `progress_map`) — <https://github.com/timholy/ProgressMeter.jl>
- OhMyThreads.jl 0.8.9: `ext/ProgressMeterExt.jl` — <https://github.com/JuliaFolds2/OhMyThreads.jl>
- ProgressLogging.jl 0.1.6: `README.md`, `src/ProgressLogging.jl` — <https://github.com/JuliaLogging/ProgressLogging.jl>
- Bonito.jl 5.2/5.3: `README.md`, `Project.toml`, `src/Bonito.jl` exports, `docs/src/deployment.md` — <https://github.com/SimonDanisch/Bonito.jl>
- HypertextTemplates.jl, JobSchedulers.jl, Malt.jl, SQLite.jl: README and `Project.toml` on GitHub.
- htmx: <https://htmx.org/>, <https://htmx.org/docs/>, <https://htmx.org/extensions/sse/>, and the
  repository's `LICENSE` — <https://github.com/bigskysoftware/htmx>
- GitHub API (`repos/…`, `releases`, issue search) for release dates, last push and open issues.
