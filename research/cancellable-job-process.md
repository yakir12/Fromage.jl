# How a running Fromage job can be cancelled and survive a segfault

Research for #442 (map: #439). Written 2026-11-14 against Fromage v0.9.7, Julia 1.13.3, Linux
(Debian 12, systemd 252), on the 32-thread / 125 GB machine the site would run on.

Every claim below is tagged with where it comes from: **[src]** a file read in this repo or in a
package's source, **[doc]** official documentation, **[exp]** a throwaway experiment run for this
ticket (scripts described in the appendix; none touched `src/`, `test/` or the test suite, and no
tracking run was started). What was *not* verified is collected in its own section at the end.

## Answer in brief

- **In-process cancellation is not viable on Julia 1.13.** There is no supported way to stop a task
  from outside. The one mechanism people use, `schedule(t, InterruptException(); error = true)`, is
  documented as incorrect on a started task, did not interrupt a task inside a C call or a
  non-yielding loop when tried, and took the whole process down afterwards. When it does land (on a
  task parked in `tmap`'s `fetch`), the parent dies and its children keep running to completion.
- **A separate process, killed by signal, is the only reliable cancel**, and it is also the only
  thing that contains a segfault or an OOM kill. Every option surveyed reduces to that; they differ
  in what they give back afterwards and in whether the job outlives the web server.
- **Recommendation: two tiers.**
  1. *Tracking jobs* (queued, long): one fresh `julia --project` child per job, started with a plain
     `run(...; wait = false)` in its own process group, talking to the site through files in a
     per-job folder. Cancel is `SIGTERM` to the process group, then `SIGKILL`. Optionally wrap the
     same command in `systemd-run` to get cgroup cleanup, a memory cap and an explicit OOM verdict.
  2. *Verification* (immediate, iterated): a long-lived warm worker per open submission, via
     **Malt.jl**, which is what Pluto uses for exactly this. `Fromage.Memo` lives in that worker, so
     the fix-a-row-and-recheck loop re-reads nothing, and a crash or a hang costs one worker restart.
- **Cost to `Fromage.Memo`:** the job re-verifies from cold in its own process (the owner's estimate
  is "a couple of minutes"), in exchange for a job that is a pure function of
  `(data_folder, parameters)` and therefore exactly reproducible from a bug report. Keeping the memo
  across verify → `main` is possible (run `main` in the session worker) and is laid out as the
  alternative.

## 1. Why cancelling inside one process does not work

### What Fromage's work looks like

- `main` fans out with OhMyThreads at three levels: `@showprogress tmap(build, cs)` over
  rectifications (`src/main.jl:106`), `@showprogress tmap(track_run, rs, cs)` over runs
  (`src/main.jl:206`), and inside each a further `tmap`/`tforeach` (intrinsic corners in
  `src/Rectifications/from_checkerboard.jl:78`, a dozen `tforeach` in
  `src/PawsomeTracker/whole_run.jl`). Verification fans out the same way (`src/gateway.jl:165`,
  `:205`). **[src]**
- The inner loops are C: VideoIO/libav decode and encode in-process (`openvideo`,
  `open_video_out`, `src/PawsomeTracker/PawsomeTracker.jl:7`, `diagnose.jl:69`), OpenCV corner
  detection, and the AprilTag C detector. Only three things are subprocesses: `ffprobe`
  (`src/probing.jl:54`, spawned at `src/shareio.jl:115`), single-frame `ffmpeg` extractions
  (`src/Rectifications/from_checkerboard.jl:23-24`) and the final concat (`src/main.jl:44`). **[src]**
- Two process-global locks serialize C entry points: `OPENVIDEO_LOCK`, because
  `VideoIO.openvideo` is not thread-safe and races produce *wrong frames, not errors*; and
  `APRILTAG_LOCK`, because the AprilTag detector is not reentrant and segfaults under concurrent
  calls. The lock does not cover the GC race of #406. (DECISIONS.md, "`VideoIO.openvideo` is not
  thread-safe" and "The AprilTag C detector is not reentrant"; CLAUDE.md §3.) **[src]**

So a job is, at any instant, N tasks most of which are inside a foreign call, some holding a global
lock, with native handles (decoders, writers, detectors) open.

### What Julia 1.13 offers

- `schedule(t, val; error = true)` carries this warning in the manual: "It is incorrect to use
  `schedule` on an arbitrary `Task` that has already been started."
  ([Base docs, Tasks](https://docs.julialang.org/en/v1/base/parallel/#Base.schedule)) **[doc]**
- Tried on 1.13.3 with 4 threads **[exp]**:

  | target task | result |
  | --- | --- |
  | inside a C call (`usleep` for 3 s) | not interrupted: the call ran its full 3 s, and the exception was delivered when the task was already finishing. The runtime printed `fatal: error thrown and no exception handler available`; in one of two runs of the same script it also printed `INTERNAL TASK ERROR: attempt to switch to exited task` and carried on, in the other **the whole process exited with code 1** |
  | pure-Julia loop with no yield point | not interrupted: ran its full 3 s, then the same `fatal: error thrown…` message (seen in the run that got this far) |
  | parked in `tmap`'s `fetch` (the legitimate case) | parent failed with `TaskFailedException` in 0.03 s; **all three children ran their full 3 s** afterwards |

  The third row is the best case, and it is still not a cancel: the tasks doing the work are
  orphaned, keep their threads, their locks and their open decoders, and a next job started in the
  same process would run beside them.
- A cooperative flag checked between frames would be new machinery threaded through every loop in
  `PawsomeTracker`, would still not interrupt a decode stuck on the CIFS share (the retry loop in
  `ShareIO` exists because those reads stall and fail), and does nothing for a segfault.
- Julia's own answer is not released. A cancellation API (`cancel!` on a token source,
  `@cancel_check` points, foreign calls opt in with `@assume_effects :reset_safe`) is in
  development for 1.14, is "mostly cooperative", and the one write-up read here says it may be
  pulled from 1.14 and reassessed for 1.15
  ([J. Nissen, "Cancellation in Julia 1.14", 2026-10-26](https://viralinstruction.com/posts/cancellation/);
  [1.14-dev NEWS](https://docs.julialang.org/en/v1.14-dev/NEWS/)). Even when it ships, libav, OpenCV
  and AprilTag calls would each need to be declared reset-safe, which the two hazards above say
  they are not. **[doc, secondary for the status]**
- A segfault in any thread kills the process whatever the task structure. The AprilTag one has
  happened here (DECISIONS; #406). If the web server is that process, the site goes down with it.

Existing in-process schedulers confirm rather than escape this: JobSchedulers.jl (v1.0.1,
2026-07-04) implements `cancel!` as exactly `schedule(job.task, InterruptException(), error=true)`
(`src/job_state_change.jl:211`), and its `Cmd` jobs are `run(command)` inside such a task. **[src]**
`Malt.interrupt` and `Distributed.interrupt` are a `SIGINT` to the worker (Malt `src/Malt.jl:714`;
Distributed `src/managers.jl:529`, `kill(config.process, 2)`), which becomes an
`InterruptException` in the request task only. Tried with Malt: the host got its
`InterruptException` back in 0.7 s while all four C-call tasks in the worker carried on. **[src, exp]**

## 2. What a separate process gives, measured

All of this is one experiment: a supervisor Julia spawning a child Julia with 4 threads. **[exp]**

**Cancel.** Child with every thread inside a C `sleep(300)` plus a grandchild process:

| signal sent to | child died in | `Process` fields | `atexit` hooks ran | grandchild survived |
| --- | --- | --- | --- | --- |
| `SIGINT`, child pid | 0.2 s | `exitcode=0 termsignal=2` | yes | **yes** |
| `SIGTERM`, child pid | 0.2 s | `exitcode=0 termsignal=15` | yes | **yes** |
| `SIGKILL`, child pid | 0.1 s | `exitcode=0 termsignal=9` | no | **yes** |
| `SIGTERM`, process group | 0.2 s | `termsignal=15` | not checked | no |
| `SIGKILL`, process group | 0.1 s | `termsignal=9` | no | no |

- Threads blocked in C do not delay death: signals are handled by the runtime, not by a task.
- **Signal the group, not the pid**, or an `ffprobe`/`ffmpeg` in flight is orphaned. `detach(cmd)`
  "will be run in a new process group" (docstring), so the group id is the child's pid and
  `ccall(:kill, Cint, (Cint, Cint), -pid, sig)` reaches everything it spawned. **[doc, exp]**
- `SIGINT` is the wrong signal for a job. Its meaning depends on how the child was started:
  a script file exits on it, but code run with `-e` gets an `InterruptException` in one task
  (`Base.exit_on_sigint` docstring), which is the in-process non-cancel of §1 again. Use `SIGTERM`,
  wait a few seconds, then `SIGKILL`. **[doc]**
- `SIGTERM` runs `atexit` hooks, so `mktempdir` cleanup happens and `Memo.CLIP_FOLDER` is removed.
  `SIGKILL`, a segfault and an OOM kill do not, and the clips leak. `Memo.CLIP_FOLDER` is
  `OncePerProcess{String}(mktempdir)` (`src/memo.jl:152`) and honours `TMPDIR` (checked), so start
  each job with `TMPDIR` pointing inside its own job folder and delete that folder from the
  supervisor. **[src, exp]**

**Segfault.** Child dereferences a bad pointer inside a spawned task:

- `Process`: `exitcode=0 termsignal=11`, `success(p) == false`.
- stderr (11 lines) is Julia's own crash report: `[pid] signal 11 (1): Segmentation fault`,
  `in expression starting at …`, then the mixed Julia/C backtrace (`unsafe_load at ./pointer.jl:151`,
  the user function with file and line, `jl_apply`, `start_task`) and an allocation summary. It is
  written by the dying process, so it is only recoverable if stderr was going somewhere durable.
  **Redirect the child's stderr to a file in the job folder from the start.**
- `SIGQUIT` makes a live process print every thread's task backtraces before dying
  (`termsignal=3`). That is the diagnostic for a job that *hangs*: send it before the kill.

**OOM.** Child allocating without bound, under a 300 MB cgroup cap:

- As a scope: killed, shell status 137 (`SIGKILL`). From the parent's side that is
  indistinguishable from someone else's `kill -9`, so "termsignal 9 that the site did not send" is
  the heuristic.
- As a transient service, `systemd-run --user --wait --collect -p MemoryMax=300M …` printed
  `Finished with result: oom-kill` / `Main processes terminated with: code=killed/status=KILL`.
  That is an explicit verdict, and `systemctl show -p Result` returns the same string. **[exp]**

**A Julia exception.** The child catches at top level and writes
`showerror(io, e, catch_backtrace())` to a file, then exits non-zero. A failure inside `tmap`
arrives as a `TaskFailedException`, and `showerror` prints the outer trace followed by
`nested task error:` with the inner exception and its own stack trace, so the frame that actually
threw is in the text. Exit code 3 came back as `exitcode=3 termsignal=0`. Text is the right
transport: it needs no types shared between the two processes, and it is what goes in the GitHub
issue anyway. **[exp]**

**Progress.** `@showprogress` draws on stderr with carriage returns and `ESC[K` even when stderr
is not a terminal (seen in the captured output: `Parsing runs.csv...  33%|███… |  ETA: 0:00:00`),
so a redirected log holds the bar as a stream of overwrites. The last `\r`-delimited segment is the
current state. How progress should be *reported* is a separate question; the transport is settled
by any of the options below (a log file to tail, a pipe, or a channel).

**Latency**, each in a fresh process on this machine **[exp]**:

| step | time |
| --- | --- |
| `julia -e 1` | 0.15 s |
| `using Fromage`, 32 threads, caches warm | 10.1 – 10.5 s, peak RSS ≈ 0.9 GiB |
| `using Fromage` after an environment change (precompiling) | 2 min 21 s, once |
| first `Fromage.verify` on a dataset whose media do not exist (pure JIT + parse) | 4.3 s |
| second `verify`, same process | 0.12 s |
| bare `Malt.Worker()` | 2.3 s |
| bare `Distributed.addprocs(1)` | 4.9 s |

So a fresh process costs about 15 s before verification does any real work. That is noise against
a tracking job and the whole budget of an interactive re-check. The first-call JIT of the
*tracking* path was not measured (no tracking run was allowed); only the two gateways have
PrecompileTools workloads (`src/VerifyRuns/precompile.jl`, `src/VerifyRectifications/precompile.jl`),
`PawsomeTracker` has none.

## 3. The options compared

All are in the General registry or the standard library and resolve on Julia 1.13.3 (installed
together in a scratch environment). **[exp]**

| | Plain child `julia --project` (`run`/`open`) | Malt.jl 1.5.0 (2026-10-24) | Distributed stdlib / DistributedNext 1.3.2 (2026-08-18) | DaemonMode.jl 0.1.10 | JobSchedulers.jl 1.0.1 |
| --- | --- | --- | --- | --- | --- |
| Isolation from the site | full | full | full | **none**: scripts are `eval`ed inside the daemon | **none** for Julia jobs (tasks) |
| Cancel | signal to the process group | `Malt.stop`: `exit`, then SIGTERM, then SIGKILL, to the worker pid | `rmprocs`: remote `exit()`, after 15 s SIGQUIT, then SIGKILL (`managers.jl:743-770`) | not offered | `schedule(…InterruptException…)`, §1 |
| Children of the job on cancel | killed with the group | **survive** `kill(w)` (measured); worker is detached so `kill(-pid)` works by hand | not tested | n/a | n/a |
| Segfault seen as | `termsignal=11` + crash report in the stderr file | `TerminatedWorkerException` within 1 s; `w.proc.termsignal == 11`; crash report on `w.stderr` if you read it | `ProcessExitedException(2)`; crash report printed on the **host's stdout** as `From worker 2:` lines; signal number not exposed publicly | daemon dies | site dies |
| Julia exception back as | text file you write | `Malt.RemoteException` with `message::String`: the full `showerror` text including nested task errors | `RemoteException` holding a `CapturedException` (object + backtrace; types must exist on the host) | printed to the client socket | task result |
| Progress channel | log file / pipe / status file | `Malt.worker_channel`, or stdout/stderr pipes | `RemoteChannel` | stdout | in-process |
| Warm start (skips the 15 s) | no: one process per job | yes: keep the worker | yes: keep the worker | yes | n/a |
| Outlives a web-server restart | **yes** (detached, state on disk) | no: host kills or loses the worker with the socket | no: workers exit with the master | n/a | n/a |
| New dependencies | none | Malt (stdlib deps + RelocatableFolders, already a Fromage dep) | none / one | one | several (JLD2, Term, PrettyTables, …) |

Notes on the table:

- **Malt** describes itself as "focused on process sandboxing, not distributed computing" and is
  what Pluto runs notebooks in ([docs](https://juliapluto.github.io/Malt.jl/stable)). Its docs say
  the worker shares the manager's process group; the source says the opposite (`detach=true`,
  `src/Malt.jl:134`) and the measured pgids differ. The source is right. One trap: the worker's
  stdout and stderr are OS pipes that the host must drain. With the default `monitor_stderr=true`
  Malt relays them to the host's stderr, prefixed; with `false` nobody reads them, and a job that
  draws progress bars will eventually block on a full pipe. Relay them into a per-job file.
  **[doc, src, exp]**
- **Distributed** works, and its `RemoteException` is the richest error object, but it is built for
  a cluster: one global worker pool per process, all-to-all topology by default, crash output
  interleaved into the host's stdout. DistributedNext is the same design developed outside the
  stdlib release cycle; it was installed but not exercised. **[src, exp]**
- **DaemonMode** solves start-up latency only, and by removing the isolation this ticket is about.
  Its last GitHub release is from 2021. Not a candidate. **[src]**
- **ConcurrentUtilities.Workers** (v2.8.0, 2026-10-29) is a third worker implementation of the same
  shape (`Worker`, `remote_eval`, `terminate!`, `WorkerTerminatedException`; detached child;
  SIGTERM → SIGINT → SIGKILL escalation, `src/workers.jl:100-116`). Read, not run. It is the engine
  under ReTestItems; nothing here needs it over Malt. **[src]**
- **systemd-run** is not a Julia package but is the established Linux answer to "kill this job and
  everything it started, cap its memory, tell me how it died", and it composes with the plain-child
  column: the command is the same, prefixed. `systemctl --user stop <unit>` sends SIGTERM to the
  whole control group and SIGKILL after the stop timeout
  ([systemd.kill(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.kill.html)).
  The user manager is running on this machine, but `Linger=no`, so user units stop when the owner
  logs out; a site run as a system service, or `loginctl enable-linger`, removes that. **[doc, exp]**

### Cutting start-up latency

- **A long-lived worker** removes it entirely and is the only option that also keeps
  `Fromage.Memo`. Costs ≈ 0.9 GiB resident per idle worker.
- **PrecompileTools workloads** already cover both gateways. A tracking workload would need
  bundled media, and `src/VerifyRuns/precompile.jl` records the constraint: the memo caches are
  `const`, so anything a workload reads is serialized into the package image with the build
  machine's paths. A workload must not populate them (or must `empty_caches!` before it ends).
- **A PackageCompiler sysimage** (v2.4.5, 2026-10-20, `julia = "1.10"` compat) would cut the 10 s
  load. Its documented price is that packages in it are "locked" to the versions present at build
  time ([docs](https://julialang.github.io/PackageCompiler.jl/stable/sysimages.html)). Fromage
  releases on every green merge to `main`, so the image would need rebuilding on every update of
  the site, and the same baked-const caveat applies. Not worth it for jobs that run for minutes to
  hours; unnecessary for verification once the worker is warm. Not built or tested here.

## 4. What a separate process does to `Fromage.Memo`

What the memo is **[src: `src/memo.jl`, `src/main.jl`, DECISIONS "The memo is keyed on the path, and
never revalidated"]**:

- Eight process-global `LRU` caches: ffprobe results, `.mat` metadata, four kinds of verification
  detection, built rectifications, and tracked runs with their diagnostic clips.
- Lifetime is the Julia process ("the session"). Keys are resolved paths plus specifications;
  nothing is ever revalidated against the file. `Fromage.empty_caches!()` or a new process is the
  only invalidation.
- A `main` after a `verify` in the same process re-probes and re-detects nothing; a second `main`
  rebuilds and re-tracks only what changed.
- Tracked runs own files: each clip sits in a subfolder of `Memo.CLIP_FOLDER`, a per-process temp
  folder, removed by the cache's finalizer or at process exit.

Consequences of process boundaries:

1. **Nothing crosses a process boundary.** A job started in a fresh process verifies from cold,
   then builds and tracks from cold. There is no on-disk form of the memo, and DECISIONS records
   that `mtime`-based revalidation was considered and declined, so a persistent cache would be a
   new design with a known objection, not existing machinery.
2. **The iterate loop is where the memo pays**, and on the site that loop is verification: select a
   folder, read the issues, fix a csv row, check again. In a fresh process each check costs ~15 s
   of start-up plus every read from cold. In a warm worker the second check costs only what the
   edited row changed. Measured on a media-less dataset: 4.3 s first, 0.12 s second. This is the
   case for a long-lived verification worker.
3. **verify → `main` reuse is the smaller prize.** It saves the verification reads once per job.
   The owner's figure for verification is "a couple of minutes in most cases" against a "usually
   much longer" job. It was not measured here.
4. **The memo's caveat gets sharper on a server.** Users replace videos and `.mat` files in place
   on the share, and a long-lived worker serves the verdict of the file it replaced. A session
   worker therefore needs a "check again from scratch" action (restart the worker, or
   `empty_caches!`) and an idle timeout. A job in a fresh process has no such exposure: it
   re-verifies the files as they are when it starts, possibly hours after submission, which is
   also the honest test of the contract "if the csv files pass verification then Fromage is
   guaranteed to work".
5. **Reproducibility.** A job run in a fresh process is a function of `(data_folder, parameters,
   Fromage version)` and nothing else. A job run in a session that has verified, re-verified and
   perhaps tracked before has the memo's history as a hidden input. The failure report the map asks
   for ("the exact setup and call so I can reliably recreate the issue") is only exact in the first
   case.
6. **Clip cleanup.** A killed process leaks its clip folder (§2). Per-job `TMPDIR` fixes it.

## 5. Recommendation

**Tracking jobs: one fresh, detached child per job; files for state; signals for cancel.**

- Start: `run(pipeline(detach(setenv(cmd, …)); stdout = log, stderr = log); wait = false)` where
  `cmd` is `julia --project=<site env> --threads=<n> <runner script> <job folder>` and the
  environment sets `TMPDIR=<job folder>/tmp`. Keep the `Process`; record the pid in the job folder.
- In: the runner reads the job's request (data folder, parameters) from a file in the job folder.
  That file is also the reproduction recipe.
- Out: `log` (stdout + stderr, including progress bars and any crash report), and on a caught
  exception an error file with `showerror(io, e, catch_backtrace())`; distinct exit codes for
  "verification issues" and "threw".
- Status, from the supervisor: `process_running(p)`; then `p.exitcode` and `p.termsignal` classify
  the end as done / verification issues / exception (error file) / crashed (`termsignal` 11, 6, 7,
  with the crash report at the tail of `log`) / killed by the site / killed by something else
  (`termsignal` 9 not sent by the site: presume OOM).
- Cancel: `SIGTERM` to `-pid`, wait a few seconds, `SIGKILL` to `-pid`, delete the job folder. For
  a *hung* job the owner wants diagnosed, `SIGQUIT` first to get every thread's backtrace into the
  log.
- Hardening, same command, when wanted: prefix with
  `systemd-run --user --unit=fromage-job-<id> --collect -p MemoryMax=…`, cancel with
  `systemctl --user stop`, and read `Result` (`success`, `exit-code`, `signal`, `oom-kill`).

Why this and not a worker library for jobs: it is the only option whose job survives a restart or
crash of the web server and can be re-adopted from disk; the crash report is durable by
construction; nothing has to be serialized between processes; no dependency is added; and the job
is reproducible by running the same command by hand. The ~15 s start-up is irrelevant at this
scale. One job at a time (the map's queue) also means the job can take all threads.

**Verification: one warm Malt worker per open submission.**

- `Malt.Worker(; exeflags = ["--project=…", "--threads=…"])`, `using Fromage` once, then
  `remote_call` `verify` for each check. The memo makes re-checks cheap.
- A check that hangs or a user who leaves: `Malt.stop(w)` (plus `kill(-pid)` for stragglers). A
  segfault: `TerminatedWorkerException`, `w.proc.termsignal`, restart the worker, report.
- Return plain data (or the issue report as text) rather than the annotated `DataFrame`s, so
  host and worker need not agree on types.
- Give it "check from scratch" and an idle timeout (§4.4), and relay its stderr to a file.

Trade-offs accepted by this recommendation:

- The job re-verifies from cold: a couple of minutes per job (owner's estimate), bought back as
  reproducibility and as a fresh look at files that may have changed while the job queued.
- Two mechanisms instead of one. The single-mechanism alternatives are both coherent:
  - *Malt for everything, memo kept:* run `main` in the submission's session worker. The job then
    reuses every read and detection its verification did. Costs: the job dies with the web server,
    is not reproducible from its inputs alone (§4.5), inherits the stale-file exposure (§4.4), and
    cancelling it throws away the session's memo.
  - *Plain children for everything:* a verification is also a fresh child. Simplest, and every
    re-check pays ~15 s plus all reads from cold, which defeats the "responsive" requirement of the
    map's question 2.
- Idle session workers hold ≈ 0.9 GiB each; with ~10 users on a 125 GB machine that is affordable,
  and the idle timeout bounds it.
- Verification and a running job compete for the same 32 threads. Thread counts per process
  (`--threads`) are the knob; no measurement was made.

## What was not verified

- **No real crash in ffmpeg, OpenCV or AprilTag was reproduced.** The segfault experiments
  dereference a bad pointer from Julia. A fault on a thread the C library created itself may print
  a thinner backtrace than the one shown.
- **No tracking run and no test suite was run**, so: the JIT latency of the first `main` in a fresh
  process, the actual duration of verification on a real dataset, and the behaviour of a kill
  during a decode from the CIFS share are all unmeasured. A thread in uninterruptible I/O on a
  stalled share may delay even `SIGKILL`; not tested.
- **The latency figures loaded the main checkout's `src/`** through its `Manifest.toml`, not this
  worktree (which has no manifest). Same version, v0.9.7.
- **Julia 1.14 cancellation** was read from one blog post and a search summary of the dev NEWS,
  not from the PRs; whether it ships in 1.14 or 1.15 is open.
- **PackageCompiler** was installed, not used. Whether a Fromage sysimage builds on 1.13 with
  OpenCV and VideoIO inside is unknown.
- **DistributedNext** was installed and assumed to behave as the stdlib does; not run.
  **ConcurrentUtilities.Workers** and **JobSchedulers** were read, not run. Whether interrupting a
  JobSchedulers `Cmd` job kills the command was not tested.
- **systemd**: tested as transient `--user` units from an interactive login, and only the OOM
  path. `systemctl stop`, its SIGTERM-then-SIGKILL sequence over the control group, and behaviour
  under a system service or with linger were not tried; the description of them above is the
  documented default and the man page was not re-read for this ticket.
- **Malt's stderr pipe filling up** is an inference from the source (unread `Pipe`), not something
  observed blocking.
- Linux only. Nothing here was considered for macOS or Windows.

## Appendix: the experiments

Run from a scratch folder, Julia 1.13.3, nothing written into the repo.

1. *In-process interruption.* Spawn a task in `ccall(:usleep, …)` for 3 s, and one in a
   time-bounded `x += sin(x)` loop; `schedule(t, InterruptException(); error = true)` after 0.3 s;
   `fetch`. Then `Threads.@spawn tmap(child, 1:3)` with 3 s children, interrupt the parent, count
   finished children (`-t 4,1` so the main task has a thread of its own).
2. *Child process.* Supervisor spawns `julia -t 4 child.jl <mode>`: `segv`
   (`unsafe_load(Ptr{Int}(8))` in a spawned task), `throw` (`sqrt(-1.0)` in a spawned task, caught,
   written with `showerror`, `exit(3)`), `busy` (a `sleep 300` grandchild, then every thread in
   `ccall(:sleep, …)`), `atexit` (same plus a hook that writes a file), `oom` (unbounded `fill`).
   Signals sent with `kill(p, sig)` or `ccall(:kill, …, -getpid(p), sig)` on a `detach`ed command;
   liveness of the grandchild by `kill(pid, 0)`.
3. *Malt* and *Distributed*: the same exception, C-call interrupt, kill and segfault through
   `Malt.remote_eval(_fetch)` and `remotecall_fetch`.
4. *systemd*: `systemd-run --user --scope -p MemoryMax=300M -p MemorySwapMax=0 julia child.jl oom`
   and the same as `--wait --collect --unit=…`.
5. *Latency*: `time julia --project -t auto -e 'using Fromage'` three times; a script timing
   `using Fromage` and two `Fromage.verify` calls on `examples/` (whose media do not exist).
