# Which General-registry packages supply the tracking building blocks

Research for #338 (child of map #335). Question: for each building block of a slower, more
robust tracker for flagged runs, which maintained packages in Julia's General registry provide
it, and how well do they fit? Fit means: per-frame arrays of candidate positions and scores, a
single target, offline processing of a whole clip, pure Julia (no Python/ML stack), and
resolvable next to Fromage's current `[compat]`.

Checked 2026-09-23 on Julia 1.13.0. Every row below was installed, unless it is marked
otherwise. The method is described at the end.

## Summary

"+N" is the number of packages Fromage's Manifest gains when this one is added, measured by adding
it to a copy of the real Project + Manifest.

| # | Building block | Recommended package | Latest release | +N deps | Verdict |
|---|---|---|---|---|---|
| 1 | Candidate extraction (local maxima, LoG blobs) | **ImageFiltering** (already a dep): `findlocalmaxima`, `findlocalminima`, `blob_LoG`, `Kernel.DoG`/`LoG`, `mapwindow` | 0.7.12, 2025-08-10 | **0** | Good fit, and nothing to add |
| 2a | Whole-clip optimal path (Viterbi) | **HiddenMarkovModels** (JuliaStats): `viterbi`, `forward_backward` with a time-dependent `AbstractHMM` | 0.7.1, 2026-06-25 | +15 | Good fit, prototyped (below) |
| 2b | Shortest path on a DAG | **Graphs** + SimpleWeightedGraphs: `dijkstra_shortest_paths`, `bellman_ford_shortest_paths`, `enumerate_paths` | 1.15.0, 2026-09-07 | +2 / +3 | Works; no DAG-specific solver (see below) |
| 2c | Frame-to-frame assignment | **Hungarian** (`hungarian(cost)`), LinearAssignment (`linear_assignment`) | 0.7.0, 2023-01 / 0.1.0, 2024-09 | +1 / +1 | Solver only. **No TrackMate-style LAP linker with gap closing exists** |
| 3 | Kalman / RTS smoother / IMM / particle filter | **LowLevelParticleFilters**: `KalmanFilter`, `forward_trajectory`, `smooth`, `IMM`, `ParticleFilter`, UKF/EKF | 3.31.1, 2026-06-16 | +29 | Best fit; its docs already contain a dung-beetle example |
| 4a | Template matching / NCC | **OpenCV** (already a dep): `matchTemplate`, `phaseCorrelate`; or **TemplateMatching** (pure Julia) | 4.9.0, 2026-06-05 / 0.1.2, 2024-02 | 0 / +1 | Fit. TemplateMatching is tiny but has little use behind it |
| 4b | Optical flow | **ImageTracking**: `optical_flow(…, LucasKanade(…))`, `Farneback` | 0.3.0, 2023-11-03 | **+54** (pulls all of `Images`) | Works (verified), but heavy and slow-moving |
| 5 | Local contrast / adaptive threshold | **ImageContrastAdjustment** (`AdaptiveEqualization` = CLAHE), **ImageBinarization** (`AdaptiveThreshold`, `Sauvola`, `Niblack`); also `OpenCV.createCLAHE`/`adaptiveThreshold` | 0.3.13, 2026-05-01 / 0.3.1, 2024-10 | +1 / +2 | Good fit, light |
| 6 | Robust background model (MOG2/ViBe/KNN) | **None in pure Julia.** OpenCV_jll ships `libopencv_video`, but OpenCV.jl 4.9.0 does not wrap it | — | — | **Gap: would have to be written** |

## 1. Multi-candidate extraction per frame

**ImageFiltering 0.7.12** is already a Fromage dependency and has everything needed. Verified in
Fromage's own environment:

- `findlocalmaxima(img; window, edges)` and `findlocalminima(img; window, edges)`
  (`src/extrema.jl:117`, `:125`). Each returns a `Vector{CartesianIndex}`. A dark beetle is a
  minimum, or a maximum of the negated DoG response.
- `blob_LoG(img, σscales; edges, σshape, rthresh)` (`src/extrema.jl:72`) returns
  `Vector{BlobLoG}`, whose fields are `(:location, :σ, :amplitude)`. That is already a candidate
  list with a position, a scale and a score. Smoke test: two Gaussian blobs were recovered at the
  right `CartesianIndex` with amplitudes in the right order.
- `Kernel.DoG(σ)` and `Kernel.LoG(σ)` for the current approach, and `mapwindow` for arbitrary
  local statistics.

Note that `blob_LoG` lives in **ImageFiltering**, not in ImageFeatures or Images.
(`gh search code --owner JuliaImages blob_LoG` finds it only in `ImageFiltering.jl/src/extrema.jl`.)
ImageFeatures 0.5.3 exports keypoint and descriptor machinery (`Keypoint`, `match_keypoints`,
`hough_*`), not blob detection, and adding it costs +68 packages. It is not needed.

Other options, not needed:

- Peaks.jl (1-D only).
- LocalFilters 2.1.1: fast morphological local min/max, +4 deps. Useful only if `mapwindow`
  turns out to be too slow.
- ImageMorphology 0.4.7: +15 deps, pulls LoopVectorization.

## 2. Whole-clip optimal path over per-frame candidates

### 2a. Viterbi / HMM — HiddenMarkovModels.jl (recommended)

- JuliaStats org. 124★, JOSS paper, CI with Aqua and JET, 0.7.1 released 2026-06-25, +15 deps.
  [README](https://github.com/JuliaStats/HiddenMarkovModels.jl) states: "Time-dependent or
  controlled HMMs are supported out of the box", observations can be arbitrary Julia objects, and
  inference functions have allocation-free versions.
- API, verified with `methods`: `viterbi(hmm::AbstractHMM, obs_seq, control_seq; seq_ends)`
  returns `(state_seq, logL)`. To define a custom model, subtype `AbstractHMM` and implement
  `initialization(hmm)`, `transition_matrix(hmm, control)` (or `log_transition_matrix`) and
  `obs_distributions(hmm, control)`. Emission objects only need
  `DensityInterface.logdensityof`. See
  [`examples/temporal.jl`](https://github.com/JuliaStats/HiddenMarkovModels.jl/blob/main/examples/temporal.jl).
- **Index convention, checked in the source** (`src/inference/viterbi.jl`, `_viterbi!`): the
  step *into* frame `t` uses `log_transition_matrix(hmm, control_seq[t])`. So with
  `control = frame index`, `transition_matrix(h, t)` must map the candidates of frame `t-1` to
  those of frame `t`.
- **Constraint:** the number of states is fixed. Frames with fewer candidates need padding slots
  with a `-Inf` log-score. A "target not detected" slot fits naturally. The code ends with
  `@argcheck isfinite(logL)`, so at least one path must stay finite.
- **Prototype** (throwaway, not in the repo). States are K candidate slots, the emission is a
  candidate log-score, and the transition is a Gaussian on the displacement (a random walk).
  - It runs as designed.
  - Scaling: 18,000 frames × 30 candidates, about 10 min at 30 fps, took **0.49 s** for Viterbi.
  - In a synthetic capture scenario, a higher-scoring "shadow" appears 8 px from the target for
    61 of 300 frames and then drifts away. A windowed-greedy tracker (a stand-in for today's
    behaviour) stayed on the target in 57% of frames and never recovered. Viterbi stayed on the
    target in 79%.
  - That 79% matches Viterbi following the shadow for exactly the capture window
    (1 − 61/300 = 80%) and then returning. This is the correct MAP answer for a random-walk
    model, because a slowly moving distractor that scores higher every frame wins. Rejecting it
    takes a better motion or appearance model, such as velocity in the state (candidate pairs,
    K² states) or an appearance term. That is a modelling decision, not a package limitation.

HMMBase.jl, the predecessor, is **archived** (GitHub `archived: true`, last release 2020). Do not
use it.

### 2b. Shortest path on a DAG — Graphs.jl

- Graphs 1.15.0 (2026-09-07, 537★, extensive CI) plus SimpleWeightedGraphs 1.5.1 add only
  +2 / +3 deps.
- Verified: `dijkstra_shortest_paths` + `enumerate_paths` on a `SimpleWeightedDiGraph` returns the
  expected path.
- **No DAG-specific shortest-path solver:** the only DAG helpers exported are `dag_longest_path`
  and `random_orientation_dag`. `topological_sort` exists.
- Dijkstra needs non-negative weights. Negative log-likelihood costs are non-negative, so it
  works, but it is O(E log V) instead of the O(E) of a topological sweep.
- For a frame-layered graph, the Viterbi recursion in 2a *is* the DAG shortest path, and HMM.jl
  already provides it with less plumbing. Graphs.jl only earns its place if the graph is not
  layered, for example with explicit skip edges for occlusion gaps.

### 2c. Global linking / assignment

- **Hungarian.jl 0.7.0**: `hungarian(costMat::AbstractMatrix)` returns `(assignment, cost)`.
  Verified. 47★, +1 dep. Last release 2023-01 and the repo was last pushed 2023. Stable, not
  actively developed.
- **LinearAssignment.jl 0.1.0**: `linear_assignment`, `linear_assignment!`, sparse workspaces.
  1★, +1 dep, CI. Maturity is low.
- **Not recommended:**
  - Munkres.jl: last push 2018, no CI.
  - LapSolve.jl: 2★, 2020.
  - GraphsOptim.jl: +47 deps, pulls JuMP and HiGHS.
  - JonkerVolgenant_jll: a binary only, with no Julia API package.
- **Gap:** no General package implements a TrackMate/u-track-style two-stage LAP linker with
  gap closing, splitting and merging. With a single target, that problem reduces to 2a anyway.
- BlobTracking.jl (baggepinnen), a multi-blob LoG + Kalman + Hungarian tracker, is the nearest
  match in spirit. It **cannot be installed next to Fromage**: its `[compat]` caps Images at
  ≤ 0.25.3 and VideoIO at 0.x, while Fromage's ImageTransformations requires Images 0.26 and
  Fromage needs VideoIO 1.x. The resolver's error is reproduced in the method section. It is
  also multi-target, online, and depends on the Interact GUI stack.

## 3. Motion models and smoothers

**LowLevelParticleFilters 3.31.1** (released 2026-06-16, 159★, CI and docs, +29 deps, pulls
ForwardDiff and LoopVectorization) is the clear pick.

- Verified present: `KalmanFilter(A, B, C, D, R1, R2[, d0]; Ts, …)`,
  `forward_trajectory(kf, u, y)` → `KalmanFilteringSolution`, and `smooth(sol, kf, u, y)` →
  `KalmanSmoothingSolution` with fields `(:sol, :xT, :RT)` (the RTS smoother). `IMM(models, P, μ)`,
  `ParticleFilter`, `AuxiliaryParticleFilter`, `UnscentedKalmanFilter` and
  `ExtendedKalmanFilter` are also present.
- A constant-velocity 2-D model ran forward and smoothed without errors.
- **Its docs already contain two dung-beetle tutorials**, `docs/src/beetle_example.md` (particle
  filter with mode switching) and `beetle_example_imm.md` (IMM of UKFs), built from a track
  Yakir supplied. They smooth an existing single track rather than select among candidates, but
  the motion model (speed + heading, a "goal-directed" vs "searching" mode) is directly reusable.
- **Missing measurements:**
  - Particle filters skip `missing` automatically (`src/PFtypes.jl:109`: `any(ismissing, y) && return w`).
  - Kalman filters do not. The `fault_detection.md` tutorial shows the pattern: loop manually and
    omit `correct!` when `y[t]` is missing.
  - The source comments on the smoother (`src/smoothing.jl:35`, `:94`) warn that one of the two
    smoother formulations misbehaves with missing measurements, and the default avoids it.
    I did **not** test smoothing across a gap.
- LLPF is a smoother over *given* measurements. It does not choose between candidates. It is
  either the post-processing step after 2a, or its per-frame gate and likelihood can supply the
  transition term in 2a.

Alternatives:

- StateSpaceModels 0.8.0 (2026-08, 291★, +19): an econometrics model-fitting API, a poorer fit.
- KalmanFilters (JuliaGNSS) 0.1.6, 2025-08, +30.
- GaussianFilters (sisl) 0.1.3, 2025-01, +26. It also has a GM-PHD multi-target filter, which
  was not tested.
- ParticleFilters (JuliaPOMDP) 0.6.1, 2025-04: +37, pulls the POMDPs stack.
- Kalman.jl (mschauer) 0.1.5: last release 2021, unmaintained.

## 4. Appearance / template matching and optical flow

- **OpenCV.jl 4.9.0** is already a Fromage dependency (used by `Rectifications`; `PawsomeTracker`
  imports it). Present with verified signatures:
  - `matchTemplate(image, templ, method)`
  - `phaseCorrelate(src1, src2; window)` returns a global sub-pixel shift, which is relevant to
    drone drift
  - `minMaxLoc`, `accumulateWeighted`, `SimpleBlobDetector`

  Inputs are 3-D `(channel, x, y)` arrays of plain numeric types, per the method signatures.
  **Not wrapped** in 4.9.0: `calcOpticalFlowPyrLK`, `calcOpticalFlowFarneback`, `DISOpticalFlow`,
  `KalmanFilter`, `findTransformECC`, and every `Tracker*`. `names(OpenCV; all=true)` has no
  match for any of them.
- **TemplateMatching.jl 0.1.2**: pure Julia, +1 dep, CI.
  `match_template(source, template, alg)` with `SquareDiff`, `NormalizedSquareDiff`,
  `CrossCorrelation`, `NormalizedCrossCorrelation`, `CorrelationCoeff` and
  `NormalizedCorrelationCoeff`. Verified: a template cut from a random image was found at the
  correct offset. Low use (2★) and no masks.
- ImageFiltering has no normalized cross-correlation. NCC would have to be composed from
  `imfilter` and `mapwindow`, or taken from TemplateMatching or OpenCV.
- **ImageTracking.jl 0.3.0** (JuliaImages; release 2023-11, repo pushed 2026-06):
  - Verified `optical_flow(src, tgt, points::Vector{SVector{2,Float64}}, LucasKanade(iters; window_size, pyramid_levels))`
    returns `(flow, status)`. It recovered a known (1, 2) px shift exactly.
  - Also offers dense `Farneback`.
  - Costs +54 deps, because it depends on the whole `Images` metapackage, and adding it moves
    14 existing Manifest versions (Interpolations, AxisAlgorithms and others).
- SubpixelRegistration.jl (phase correlation) **cannot be installed next to Fromage**: its FFTW
  compat is 0.2–0.4 and Polynomials forces FFTW ≥ 1.
- FastLocalCorrelationCoefficients is not recommended: 8★, 2021, and its master declares a CUDA
  dependency.
- CorrelationTrackers.jl is **unrelated** despite its name. It covers porous-media correlation
  functions.

## 5. Local contrast normalisation / adaptive thresholding

- **ImageContrastAdjustment 0.3.13** (2026-05-01, +1 dep): `adjust_histogram(img, AdaptiveEqualization(nbins, rblocks, cblocks, clip))`
  (CLAHE), plus `Equalization`, `GammaCorrection`, `LinearStretching` and `Matching`. Verified on
  `Gray{Float32}`.
  **Watch out:** a plain `Pkg.add` into Fromage's environment resolved to **v0.1.0**, because the
  tiered resolver preferred not moving existing versions. Requesting 0.3 explicitly resolves
  cleanly. A `[compat]` entry of `"0.3"` is needed.
- **ImageBinarization 0.3.1** (2024-10, +2 deps): `binarize(img, AdaptiveThreshold(window_size, percentage))`,
  `Sauvola(window_size, bias)` and `Niblack(window_size, bias)`, plus global methods (`Otsu`,
  `Yen`, …). All three local methods were verified to run.
- Also available through OpenCV.jl with no new dependency: `createCLAHE(; clipLimit, tileGridSize)`
  and `adaptiveThreshold(src, maxValue, adaptiveMethod, thresholdType, blockSize, C)`.
- A local z-score, `(x − local mean) / local std`, is two `imfilter` calls with a box or Gaussian
  kernel in ImageFiltering. It needs no package.

## 6. Robust background models

**No General package provides MOG2, KNN, ViBe or similar video background models in Julia.**

- BackgroundSubtraction.jl is for *spectroscopic* data (the MCBL model) and does not apply to
  video.
- BlobTracking.jl has a `MedianBackground` buffer but cannot be installed (§2c).
- MicroTracker.jl depends on **PyCall + Conda** (trackpy) and caps Julia at ≤ 1.10. Excluded.
- OpenCV_jll's artifact does ship `libopencv_video.so` (4.10/4.13), which contains
  `BackgroundSubtractorMOG2`/`KNN`, but OpenCV.jl 4.9.0's generated bindings do not expose it.
  Using it would mean contributing bindings upstream or writing CxxWrap glue, which is not a
  "mature tested package".

The pieces for writing one are all present: per-pixel running statistics over `ImageCore`
arrays, with the temporal max/min model Fromage already has as the baseline. A per-pixel
Gaussian or a small mixture is a few dozen lines, and the testing burden falls on us.

## Excluded, and why

| Package | Reason |
|---|---|
| HMMBase | Archived, last release 2020 |
| BlobTracking | Unresolvable with Fromage's compat (Images ≤ 0.25.3, VideoIO 0.x) |
| SubpixelRegistration | Unresolvable (FFTW 0.2–0.4 against Polynomials' FFTW ≥ 1) |
| MicroTracker | PyCall/Conda (Python), `julia ≤ 1.10` |
| BackgroundSubtraction | Spectroscopy, not video |
| CorrelationTrackers | Porous-media correlation functions, not object tracking |
| Munkres, LapSolve | Unmaintained (2018 / 2020) |
| GraphsOptim | +47 deps (JuMP/HiGHS) for an assignment we can do with Hungarian |
| Kalman.jl | Last release 2021 |
| ImageFeatures | +68 deps, and blob detection is not in it (it is in ImageFiltering) |

## Method and evidence

- **Registry facts** (repo URL, latest version, version count) come from the local General
  registry through `Pkg.Registry.registry_info`. The registry was also searched by name for
  `track|kalman|background|blob|viterbi|hmm|assign|particle|lap|flow|templat|correlat|…`, and
  that is how BlobTracking, TemplateMatching, LinearAssignment, MicroTracker and
  CorrelationTrackers were found.
- **Maturity**: `gh api repos/<owner>/<repo>` for stars, last push and archived status;
  `…/releases` for the latest release date; `…/contents/.github/workflows` for CI.
- **Dependency weight**: each package was added to a copy of Fromage's real `Project.toml` +
  `Manifest.toml` (precompilation off). The reported number is the count of Manifest entries
  gained. Some adds also moved existing versions: Images, ImageFeatures, ImageTracking,
  ParticleFilters and GraphsOptim each moved about 10 jlls or Preferences.
- **Resolver failures** were reproduced with an explicit `Pkg.add` against Fromage's Manifest.
  - BlobTracking: `restricted by compatibility requirements with BlobTracking to versions: 0.20.0 - 0.25.3 — no versions left`
    (Images), with Fromage's ImageTransformations 0.10.3 requiring Images 0.26.
  - SubpixelRegistration: `FFTW … restricted by compatibility requirements with SubpixelRegistration to versions: [0.1.0 - 0.3.0, 1.4.0 - 1.10.0]`
    against Polynomials, with `no versions left`.
- **API checks** used a throwaway environment holding HiddenMarkovModels, Hungarian, Graphs,
  SimpleWeightedGraphs, LowLevelParticleFilters, ImageContrastAdjustment, ImageBinarization,
  TemplateMatching, ImageTracking, ImageFeatures, LinearAssignment and LocalFilters. In it I ran
  `methods(f)`, `names(M)` and a small smoke run of each key call. The results are quoted above.
  ImageFiltering and OpenCV were checked in Fromage's own environment.
- **Download counts**: the public package-server logs (`package_requests.csv.gz`, unique
  non-CI IPs) put the JuliaImages core and Graphs in the 10⁴–10⁵ range, Hungarian at about 10⁴,
  and LowLevelParticleFilters, ParticleFilters, StateSpaceModels and OpenCV at about 10³. They put
  HiddenMarkovModels, ImageTracking, TemplateMatching and BlobTracking at ≤ 10². The date windows
  in that file are inconsistent between packages, and the numbers are dominated by transitive
  installs, so they are only an order-of-magnitude signal. HiddenMarkovModels' low count
  reflects its recent move to JuliaStats, not its quality.

## Not verified

- Tracking accuracy on real lab footage. The only accuracy numbers here come from the synthetic
  prototype in §2a.
- LLPF's RTS smoother across gaps with missing measurements.
- GaussianFilters' GM-PHD filter, and KalmanFilters' smoother API.
- Whether OpenCV.jl's unreleased master wraps the `video` module. The master `cv_wrap.jl`
  contained none of the searched names, including `matchTemplate`, which the release *does*
  have, so master's layout differs and the check is inconclusive.
