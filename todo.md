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

## Apple Silicon (aarch64 macOS) support

Context (2026-07-10): CI on `macOS-latest` (arm64) showed Fromage's AprilTag functionality cannot
run natively on Apple Silicon — `AprilTags_jll` ships no `aarch64-apple-darwin` binaries, so
`AprilTags.libapriltag` is never defined and every tag create/detect call throws `UndefVarError`.
The rest of the suite (818/820 tests) passes on arm64 macOS. CI tests `macos-15-intel`
(x86_64-apple-darwin, where the JLL exists) as a stopgap; GitHub supports that runner into 2027.

- **Upstream aarch64 binaries (ideal).** Before doing anything, survey what's already been
  attempted: issues/PRs in JuliaRobotics/AprilTags.jl and JuliaBinaryWrappers/AprilTags_jll.jl,
  and the Yggdrasil build recipe (`A/AprilTags/build_tarballs.jl`) — is `aarch64-apple-darwin`
  merely missing from the platform list, or does the build actually fail there? The apriltag C
  library itself is plain C and builds fine on ARM Macs (Homebrew ships it), so this may be a
  small Yggdrasil PR + JLL version bump + AprilTags.jl compat bump.

- **Factor AprilTag functionality into a Pkg extension (maybe more relevant to what users
  actually need, but a serious effort).** Move all AprilTags-dependent code (calibration tag
  detection, `track_apriltag`, tag-video helpers) behind a package extension that loads only when
  the user has AprilTags.jl in their environment (`[extensions]` + `[weakdeps]` in Project.toml).
  Fromage core would then install and run everywhere — including Apple Silicon — with tag features
  lighting up where AprilTags works. Requires an API split (what does `main`/tracking do when the
  extension is absent?), moving tests into extension-conditional test sets, and deciding how
  track_calibrate declares the dependency.

## Tracks / output

- **Interpolate `missing` coordinates in AprilTag tracks.** Frames that lose a tag currently yield
  `missing` and `save2csv` writes them as empty `x`/`y` cells. The plan is to interpolate those
  gaps at some point, at which time the `ismissing` branch in `save2csv` goes away. Until then
  `save2csv` deliberately stays hand-rolled (`println`-based, not CSV.jl) — the explicit missing
  handling is the point — so don't "clean it up" in idiom passes.

## Performance / tooling

- **Set up PkgBenchmark for regression tracking.** Add a `benchmark/benchmarks.jl` `BenchmarkGroup`
  (wraps BenchmarkTools) covering representative operations — a rectification build on a synthetic
  checkerboard, a short synthetic track — so `PkgBenchmark.judge(Fromage, "branch", "main")` reports
  how much a change moved performance. `BenchmarkCI.jl` can run it in Actions and comment on PRs (the
  BestieTemplate `.gitignore` already carries a `.benchmarkci` entry). Caveat: environment-specific
  costs like concurrent VideoIO opens over a network share won't show up in a portable/synthetic
  suite — those need timing on the real data + mount.
