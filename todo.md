# TODO — deferred work

Parked ideas and follow-ups, so they don't get lost.

## AprilTag tracking

- **Fold registration into the lazy-scaling pipe (could stabilize the background model).** Scaling
  is currently lazy — it only scales the *indices* into an interpolation object (a `WarpedView`),
  at essentially no compute cost. The per-frame registration homography is the same kind of
  operation (a coordinate transform on lookups), so it could be composed into that same pipe for
  very little cost. That would effectively warp each frame into the reference frame as it's read,
  making the DoG background stack *static* (drone motion removed at lookup time) — likely a much
  more stable background model than tracking in native image space. Revisit if the background model
  ever proves to be the limiting factor.

- **Keep frames as `Gray{N0f8}` through PawsomeTracker.** The background stack is `Gray{Float32}`
  but the AprilTag detector only accepts `Gray{N0f8}`/`UInt8`, so `track_apriltag` re-detects on the
  raw `vid.img` each frame with a `collect` conversion instead of reusing the stack slices. If the
  frames stayed `N0f8` (or the stack slices were detector-compatible), detection could run directly
  on the stack. Check whether the DoG path (imfilter, background subtraction) tolerates `N0f8`.

## Performance / tooling

- **Set up PkgBenchmark for regression tracking.** Add a `benchmark/benchmarks.jl` `BenchmarkGroup`
  (wraps BenchmarkTools) covering representative operations — a rectification build on a synthetic
  checkerboard, a short synthetic track — so `PkgBenchmark.judge(Fromage, "branch", "main")` reports
  how much a change moved performance. `BenchmarkCI.jl` can run it in Actions and comment on PRs (the
  BestieTemplate `.gitignore` already carries a `.benchmarkci` entry). Caveat: environment-specific
  costs like concurrent VideoIO opens over a network share won't show up in a portable/synthetic
  suite — those need timing on the real data + mount.
