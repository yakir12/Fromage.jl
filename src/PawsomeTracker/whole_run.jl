# THE WHOLE-RUN TRACKER
#
# The online tracker (`track`) decides frame by frame. This one holds the whole run in memory and
# finds one path over all of it: every segment is read, registered and reduced into one volume, in
# csv order, and the path is the best one through that volume under a model of how the target moves
# and how it looks. Selected per run by `Tuning.whole_run`; the seam is `VerifyRuns.track(r::Run, …)`.
#
#   read_run → background → score_dark → anchor_contrast → best_path → refine
#
# Two variants, chosen by the rectification's type (`path_model`):
#
# - AprilTag footage (drone): `MotionModel`. The path steps whole seconds through a Viterbi over
#   (pixel, stopped | walking), each step drawing its displacement from the fitted kernel of the
#   state it lands in, with a no-return prior and, given `arena_radius`, an arena prior.
# - anything else (tripod): `NoMotionModel`. A per-sample Viterbi with a Gaussian step cost, on the
#   same score. The motion model was fitted on the drone runs only, and a tripod's grid is ~9× finer
#   in real units, so it is not applied there (#379).
#
# Every constant below was settled on real footage in the research this was ported from, and is
# recorded with its evidence in DECISIONS.md ("The whole-run tracker's constants"). Lengths are in
# TARGET WIDTHS (`Tuning.target_width`), so nothing here assumes a real-world unit: the fitted
# model was measured in centimetres on drone runs whose target is 6.78 cm wide, and divided through.
#
# The grid is the `downscale`d space, with square pixels: the scaled REFERENCE viewport on AprilTag
# footage (as the online AprilTag tracker's), the scaled DISPLAY frame otherwise. A grid pixel is
# the mean of the full-resolution pixels under it (`grid_frame`), not a point sample, so a small
# `downscale` does not alias the target away.

using ImageFiltering: Fill
using ImageFiltering.KernelFactors: kernelfactors
using OffsetArrays: OffsetVector
using OhMyThreads: @local, @tasks, tforeach
using CoordinateTransformations: AffineMap
using ..Rectifications: StaticRectification

# ---- the constants ---------------------------------------------------------------------------

# The path steps this many seconds at a time (the motion model's step, and the emission's window).
# Per sample, speed is localisation noise; over a second it is the target's walk.
const STEP_SECONDS = 1.0
# The emission: `EMISSION_WEIGHT` nats per z, of `contrast_like_target` (below).
const EMISSION_WEIGHT = 1.0
const PLATEAU = 0.7          # the emission rises as z up to PLATEAU × the target's own contrast …
const FALLOFF_ONSET = 1.8    # … and falls beyond FALLOFF_ONSET × it …
const FALLOFF = 1.0          # … by FALLOFF per z.

# The motion model, fitted on 88 drone runs (`out/p4/motion.json` in the research), in target
# widths. Stopped: a 2D Gaussian step of σ STOP_SIGMA (localisation, not motion). Walking: a
# two-gamma speed mixture, weights WALK_WEIGHTS, shapes WALK_SHAPES, scales WALK_SCALES (widths/s),
# plus a broad gamma(2, TAIL_SCALE) tail of weight TAIL_WEIGHT, so a real fast second is expensive
# rather than impossible; nothing walks beyond WALK_REACH widths/s. Switching, per second:
# STOP_TO_WALK and WALK_TO_STOP. `loggamma` of the shapes is precomputed: SpecialFunctions would be
# a dependency for two numbers.
const STOP_SIGMA = 0.23011759027389594
const WALK_WEIGHTS = (0.10164603748094848, 0.8983539625190514)
const WALK_SHAPES = (3.860662589597137, 8.277382682963806)
const WALK_SCALES = (0.0446679229996047, 0.07632223601461727)
const WALK_LOGGAMMA_SHAPES = (1.619527294335218, 9.08932543619079)
const TAIL_WEIGHT = 1.0e-4
const TAIL_SHAPE = 2.0       # loggamma(2) == 0
const TAIL_SCALE = 0.7374631268436579
const WALK_REACH = 3.6873156342182893
const STOP_TO_WALK = 0.12185280826339565
const WALK_TO_STOP = 0.02566281441196465

# The priors, in target widths from the start location and nats. A walking step pays RETURN_COST
# per width it moves back toward the start, once beyond RETURN_FREE. Given an arena radius, every
# step pays OUTSIDE_COST per width beyond the radius + OUTSIDE_MARGIN, and the last step pays
# EDGE_COST per width outside radius ± EDGE_BAND, capped at EDGE_CAP: runs end at the arena's edge.
const RETURN_COST = 1.356
const RETURN_FREE = 7.374631268436579
const OUTSIDE_COST = 1.356
const OUTSIDE_MARGIN = 7.374631268436579
const EDGE_BAND = 3.6873156342182893
const EDGE_COST = 6.78
const EDGE_CAP = 300.0

# Without the motion model: a per-sample step of σ NO_MOTION_SPEED widths per second, and a sample's
# score capped at NO_MOTION_CAP × the target's own contrast. The cap's value is PLATEAU's, and it is a
# separate knob: it was settled on its own, for this path (#368).
const NO_MOTION_SPEED = 1.0
const NO_MOTION_CAP = 0.7

# A run whose fastest second covers more than this many target widths is flagged (`@warn`). The
# fitted walk's p99.9 is 1.6 widths/s; every whole-run failure among 157 drone runs had a fastest
# second of 3.5–4 (#376).
const SUSPECT_SPEED = 3.0

# Each segment's sample times: the `StepRangeLen` a `range` of `Float64`s is, as the online
# tracker's `track` collects them.
const SampleTimes = StepRangeLen{Float64, Base.TwicePrecision{Float64}, Base.TwicePrecision{Float64}, Int64}

# ---- the volume ------------------------------------------------------------------------------

"""
    RunVolume

A whole run on the grid: `frames[k]` is sample `k`, `has[k]` whether it was registered (always
true without AprilTags; an unregistered sample borrows the nearest registration and scores 0), and
`tss` each segment's file times, the segments' samples following one another in `frames`. `start` is the
start location as a grid index, `anchor` the radius around it the target starts within, `width`
the target's width and `dt` the seconds between samples — all on the grid.
"""
struct RunVolume
    frames::Vector{Matrix{UInt8}}
    has::Vector{Bool}
    tss::Vector{SampleTimes}
    start::NTuple{2, Float64}
    anchor::Float64
    width::Float64
    dt::Float64
end

# A grid pixel is the full-resolution pixels under its footprint: at a downscale of 1/3, grid index
# `r` covers full indices `3r − 2 … 3r`, centred on `3r − 1`. So a grid index and a full-resolution
# index (reference on AprilTag footage, display otherwise) convert as below, both ways, everywhere
# the grid meets the frame. NOT the online tracker's `r / downscale`, which is a point sample one
# full pixel off this footprint: on textured ground that is a different volume, and it flipped two
# fragile drone runs against the research tracker this was measured on (DECISIONS, "The whole-run
# tracker's constants").
full_index(g, downscale) = (g - 0.5) / downscale + 0.5
grid_index(i, downscale) = (i - 0.5) * downscale + 0.5

# The display frame (non-AprilTag footage): full-resolution display index `(r, c, k)` → the stored
# frame's index; a display column crosses to a stored one through `sar`. The same call shape as
# `RegisteredWarp`, so `grid_frame` takes either.
struct DisplayToStored
    sar::Float64
end
(g::DisplayToStored)(x::SVector{3}) = SVector(x[1], (x[2] - 1) / g.sar + 1, x[3])

# One grid frame from the raw frame `img`: each grid pixel is the mean of `n × n` bilinear samples
# spread evenly over its footprint, `n = ceil(1 / downscale)` — at a downscale of 1/3, exactly the
# nine full pixels under it. `to_raw` maps a (fractional) full-resolution index to a raw index; a
# sample off the raw frame reads 0.
function grid_frame(img, to_raw, (R, C), downscale)
    n = ceil(Int, 1 / downscale)
    offsets = [(i - (n + 1) / 2) / (n * downscale) for i in 1:n]
    out = Matrix{UInt8}(undef, R, C)
    tforeach(1:C) do c
        for r in 1:R
            acc = 0.0f0
            for dr in offsets, dc in offsets
                p = to_raw(SVector(full_index(r, downscale) + dr, full_index(c, downscale) + dc, 1.0))
                v = bilinear(img, (p[1], p[2]))
                isnothing(v) || (acc += Float32(gray(v)))
            end
            out[r, c] = round(UInt8, 255 * acc / n^2)
        end
    end
    return out
end

# Where the target starts, as a grid index, and the radius it starts within. A `start_location`
# is a display pixel; the online tracker's search window, halved, is how far off it may be. A
# start that is searched for gets the online tracker's initial search window, halved, around
# its pixel (a `StartSearch`) or around the grid's centre (`missing`, an AprilTag run whose csv
# leaves it blank).
function anchor(start_location::NTuple{2, Int}, to_grid, tuning, _)
    return to_grid(start_location), tuning.downscale * maximum(fix_window_size(tuning.window_size)) / 2
end
anchor(s::StartSearch, to_grid, tuning, (R, C)) = to_grid(s.around), search_radius(tuning, (R, C))
anchor(::Missing, _, tuning, (R, C)) = ((R + 1) / 2, (C + 1) / 2), search_radius(tuning, (R, C))
search_radius(tuning, (R, C)) = min(R, C) / (2 * tuning.initial_search_factor)

function RunVolume(frames, has, tss, start_location, to_grid, tuning)
    sz = size(first(frames))
    start, radius = anchor(start_location, to_grid, tuning, sz)
    # a start off the grid anchors at the nearest grid pixel
    start = (clamp(start[1], 1, sz[1]), clamp(start[2], 1, sz[2]))
    dt = 1 / effective_fps(tuning.native_fps, tuning.sample_fps)
    return RunVolume(frames, has, tss, start, radius, tuning.downscale * tuning.target_width, dt)
end

"""
    read_run(segments, tuning, rectification) -> RunVolume

Read every segment of the run into one `RunVolume`, in order. With an `ApriltagRectification`
every sample is registered into the reference viewport (the tags are found as the online tracker
finds them: the whole frame until they are, then around where they were); otherwise the grid is
the display frame.
"""
function read_run(segments, tuning, rectification::ApriltagRectification)
    ds = tuning.downscale
    sz = round.(Int, ds .* reference_size(rectification))
    frames, has = Matrix{UInt8}[], Bool[]
    tss = Vector{SampleTimes}(undef, length(segments))
    seeds = map(enumerate(segments)) do (i, s)
        video(s.file, tuning.native_fps, tuning.sample_fps, s.start, s.stop, 1.0, tuning.aspect) do vid
            tss[i] = range(s.start; step = 1 / vid.sample_fps, length = vid.nframes)
            read_registered!(frames, has, vid, rectification, ds, sz, s.file)
        end
    end
    seedR = first(seeds)
    # the start location is a pixel of the run's first frame; it crosses into the reference
    # through that segment's first registration, as the online tracker's `apriltag_guess` does
    function to_grid((x, y))
        p = to_index(apply_h(seedR, SVector(stored_x(x, tuning.aspect), Float64(y))))
        return (grid_index(p[2], ds), grid_index(p[1], ds))
    end
    return RunVolume(frames, has, tss, first(segments).start_location, to_grid, tuning)
end

function read_run(segments, tuning, _)
    ds, sar = tuning.downscale, Float64(tuning.aspect)
    to_raw = DisplayToStored(sar)
    frames, has = Matrix{UInt8}[], Bool[]
    tss = Vector{SampleTimes}(undef, length(segments))
    for (i, s) in enumerate(segments)
        video(s.file, tuning.native_fps, tuning.sample_fps, s.start, s.stop, 1.0, tuning.aspect) do vid
            tss[i] = range(s.start; step = 1 / vid.sample_fps, length = vid.nframes)
            sz = (round(Int, ds * vid.height), round(Int, ds * vid.width * sar))
            for _ in 1:vid.nframes
                next!(vid)
                push!(frames, grid_frame(vid.img, to_raw, sz, ds))
                push!(has, true)
            end
        end
    end
    # a display (x, y), 0-based, is display index (y + 1, x + 1)
    to_grid((x, y)) = (grid_index(y + 1, ds), grid_index(x + 1, ds))
    return RunVolume(frames, has, tss, first(segments).start_location, to_grid, tuning)
end

# One segment's samples, registered and reduced onto the grid; returns the segment's first
# registration. A sample before the first registration is held raw until it arrives, and one
# without all its tags borrows the last registration (and is recorded as unregistered).
function read_registered!(frames, has, vid, rectification, ds, sz, file)
    ref = rectification.reference
    ids = ref.ids
    dets = [set_detector!(AprilTagDetector(rectification.family)) for _ in ids]
    try
        raw_sz = size(vid.img)
        boxes = NTuple{4, Int}[]
        seeded = false
        seedR = Hinv = SMatrix{3, 3, Float64, 9}(I)
        pending = Matrix{Gray{N0f8}}[]
        for _ in 1:vid.nframes
            next!(vid)
            tc = seeded ? detect_tags_roi!(dets, vid.img, ids, boxes, raw_sz) : detect_tags(dets[1], vid.img, ids)
            push!(has, !isnothing(tc))
            if !isnothing(tc)
                R = register(ref, reduce(vcat, tc))
                Hinv = inv(R)
                if !seeded
                    boxes = [tag_box(c, raw_sz) for c in tc]
                    seedR = R
                    seeded = true
                    for img in pending
                        push!(frames, grid_frame(img, RegisteredWarp(1.0, [Hinv]), sz, ds))
                    end
                    empty!(pending)
                end
            end
            if seeded
                push!(frames, grid_frame(vid.img, RegisteredWarp(1.0, [Hinv]), sz, ds))
            else
                push!(pending, collect(vid.img))
            end
        end
        seeded || error("no frame of $file between its start and stop held all $(length(ids)) AprilTags")
        return seedR
    finally
        foreach(freeDetector!, dets)
    end
end

# ---- the score -------------------------------------------------------------------------------

# The median of `v`, reordering it: `Statistics` is not a dependency. The middle pair's mean on an
# even length, as `Statistics.median!` has it.
function middle!(v)
    n = length(v)
    h = (n + 1) ÷ 2
    isodd(n) && return Float64(partialsort!(v, h))
    a, b = partialsort!(v, h:(h + 1))
    return (Float64(a) + Float64(b)) / 2
end

# The whole run's background: each grid pixel's median over (at most 401) evenly spaced samples.
function background(frames)
    n = length(frames)
    ks = unique(round.(Int, range(1, n; length = min(401, n))))
    R, C = size(first(frames))
    bg = Matrix{Float32}(undef, R, C)
    tforeach(1:C) do c
        buf = Vector{UInt8}(undef, length(ks))
        for r in 1:R
            for (i, k) in enumerate(ks)
                buf[i] = frames[k][r, c]
            end
            bg[r, c] = middle!(buf)
        end
    end
    return bg
end

# A normalised Gaussian of σ grid px, truncated at 3σ, as the two factors of a separable filter.
function gaussian(σ)
    h = max(1, ceil(Int, 3σ))
    w = [exp(-i^2 / 2σ^2) for i in -h:h]
    k = OffsetVector(Float32.(w ./ sum(w)), -h:h)
    return kernelfactors((k, k))
end

"""
    score_dark(vol, bg, darker_target) -> Array{Float32, 3}

Every sample's centre-surround response to a target of `vol.width`, as a z-score: the foreground
(background minus frame, for a darker target) smoothed by a Gaussian matched to the target, minus
the same at three times the width, over the frame's robust spread (median and 1.4826 × MAD of that
response). The foreground is clamped to darker-than-background before it is filtered: a bright body
(the experimenters wear white) otherwise leaves a positive ring in its negative surround, which
scores like a dark target. The spread is still the signed response's, so the scale is not.

An unregistered sample scores 0 everywhere, and so does one with no spread at all (a frame that is
the background exactly): it has no scale to score against.
"""
function score_dark(vol::RunVolume, bg, darker_target)
    R, C = size(bg)
    n = length(vol.frames)
    σ = vol.width / 2sqrt(2log(2))
    near, far = gaussian(σ), gaussian(3σ)
    z = zeros(Float32, R, C, n)
    @tasks for k in 1:n
        @local begin                     # one set of buffers per task
            fg = Matrix{Float32}(undef, R, C)
            fp = Matrix{Float32}(undef, R, C)
            s = Matrix{Float32}(undef, R, C)
            sfar = Matrix{Float32}(undef, R, C)
            flat = Vector{Float32}(undef, R * C)
        end
        if vol.has[k]
            score_sample!(view(z, :, :, k), vol.frames[k], bg, darker_target, near, far, fg, fp, s, sfar, flat)
        end
    end
    return z
end

# One sample's z into `out`, through the caller's buffers; left 0 when the response has no spread.
# Typed, not generic: JET analyses a method on its own signature, and with untyped buffers
# `imfilter!` there has union-split cases no method matches (the #381 PR's red JET run).
function score_sample!(
        out::AbstractMatrix{Float32}, frame::Matrix{UInt8}, bg::Matrix{Float32}, darker_target::Bool,
        near::Tuple, far::Tuple, fg::Matrix{Float32}, fp::Matrix{Float32}, s::Matrix{Float32},
        sfar::Matrix{Float32}, flat::Vector{Float32}
    )
    for i in eachindex(fg)
        x = Float32(frame[i])
        fg[i] = darker_target ? bg[i] - x : x - bg[i]
        fp[i] = max(0.0f0, fg[i])
    end
    imfilter!(s, fg, near, Fill(0.0f0))
    imfilter!(sfar, fg, far, Fill(0.0f0))
    flat .= vec(s) .- vec(sfar)
    med = Float32(middle!(flat))
    flat .= abs.(vec(s) .- vec(sfar) .- med)
    mad = 1.4826f0 * Float32(middle!(flat))
    mad > 0 || return out
    imfilter!(s, fp, near, Fill(0.0f0))
    imfilter!(sfar, fp, far, Fill(0.0f0))
    out .= (s .- sfar .- med) ./ mad
    return out
end

# The pixels within the anchor radius of the start: where the target is at the first sample. Never
# empty — a radius under half a pixel still holds the pixel nearest the start.
function anchor_disk(vol, R, C)
    r0, c0 = vol.start
    disk = [ix for ix in CartesianIndices((R, C)) if hypot(ix[1] - r0, ix[2] - c0) <= vol.anchor]
    isempty(disk) && push!(disk, CartesianIndex(round(Int, r0), round(Int, c0)))
    return disk
end

# The target's own contrast: the median, over the first second, of the peak z inside the anchor disk.
function anchor_contrast(z, vol)
    disk = anchor_disk(vol, size(z, 1), size(z, 2))
    ks = 1:min(size(z, 3), max(1, round(Int, 1 / vol.dt)))
    peaks = [maximum(z[ix, k] for ix in disk) for k in ks]
    return Float32(middle!(peaks))
end

# ---- the path --------------------------------------------------------------------------------

"""
    MotionModel(arena)

The path of AprilTag footage: whole-second steps under the fitted motion model and the no-return
prior, and the arena prior given `arena`, the arena's radius in target widths (`missing` for none).
"""
struct MotionModel
    arena::Union{Missing, Float64}
end

"The path of any other footage: a per-sample step cost, no motion model and no arena prior."
struct NoMotionModel end

# The variant is the rectification's type. `arena_radius` is in the rectification's real-world
# unit; `ratio` is that unit per reference pixel, so a target width is `ratio × target_width` of it.
path_model(r::ApriltagRectification, t::Tuning) = MotionModel(t.arena_radius / (r.ratio * t.target_width))
path_model(_, ::Tuning) = NoMotionModel()

"""
    whole_run_path(vol, model, darker_target) -> Vector{NTuple{2, Float64}}

The target's grid index at every sample of `vol`: the best path under `model`, each point then
localised on the uncapped score.
"""
function whole_run_path(vol::RunVolume, model, darker_target)
    z = score_dark(vol, background(vol.frames), darker_target)
    return refine(z, best_path(model, z, anchor_contrast(z, vol), vol), vol.width)
end

# The per-pixel ceiling on a sample's score, as a fraction of the target's own contrast: anything at
# least as dark as the target scores the same, so a larger dark thing is no more attractive.
function best_path(::NoMotionModel, z, za, vol)
    R, C, n = size(z)
    σ = NO_MOTION_SPEED * vol.width * vol.dt
    reach = max(2, ceil(Int, 4σ))
    offsets = [(dr, dc) for dc in -reach:reach for dr in -reach:reach if dr^2 + dc^2 <= reach^2]
    cost = Float32[(dr^2 + dc^2) / 2σ^2 for (dr, dc) in offsets]
    cap = Float32(NO_MOTION_CAP * za)
    back = Array{Int32, 3}(undef, R, C, n)
    δ = fill(-Inf32, R, C)
    for ix in anchor_disk(vol, R, C)
        δ[ix] = min(z[ix, 1], cap)
    end
    δnext = similar(δ)
    for k in 2:n
        tforeach(1:C) do c
            for r in 1:R
                best, arg = -Inf32, Int32(0)
                for (j, (dr, dc)) in enumerate(offsets)
                    rr, cc = r - dr, c - dc
                    (1 <= rr <= R && 1 <= cc <= C) || continue
                    s = δ[rr, cc] - cost[j]
                    s > best && ((best, arg) = (s, Int32(j)))
                end
                δnext[r, c] = best + min(z[r, c, k], cap)
                back[r, c, k] = arg
            end
        end
        δ .= δnext .- maximum(δnext)
    end
    return backtrack(back, offsets, argmax(δ))
end

function backtrack(back, offsets, last)
    n = size(back, 3)
    r, c = last[1], last[2]
    out = Vector{NTuple{2, Float64}}(undef, n)
    for k in n:-1:1
        out[k] = (r, c)
        k == 1 && break
        dr, dc = offsets[back[r, c, k]]
        r, c = r - dr, c - dc
    end
    return out
end

# Contrast like the target's own: it rises as z up to PLATEAU·za, then falls by FALLOFF per z beyond
# FALLOFF_ONSET·za, so something much darker than the target (a person, a head's shadow) scores LESS
# than the target does, not the same.
contrast_like_target(z, za) = min(z, Float32(PLATEAU) * za) - Float32(FALLOFF) * max(0.0f0, z - Float32(FALLOFF_ONSET) * za)

# The per-step emission, `(R, C, steps)`: EMISSION_WEIGHT × the mean over the step's `m` samples of
# `contrast_like_target` of z max-pooled over the 3×3 (the target moves under a pixel per sample).
function emission(z, za, m)
    R, C, n = size(z)
    N = cld(n, m)
    e = zeros(Float32, R, C, N)
    tforeach(1:N) do K
        ks = ((K - 1) * m + 1):min(n, K * m)
        acc = view(e, :, :, K)
        for k in ks, c in 1:C, r in 1:R
            best = -Inf32
            for cc in max(1, c - 1):min(C, c + 1), rr in max(1, r - 1):min(R, r + 1)
                best = max(best, z[rr, cc, k])
            end
            acc[r, c] += contrast_like_target(best, za)
        end
        acc .*= Float32(EMISSION_WEIGHT / length(ks))
    end
    return e
end

gamma_logpdf(v, k, θ, lgk) = (k - 1) * log(v) - v / θ - lgk - k * log(θ)

# The walking speed density (widths/s): the fitted mixture plus the broad tail.
function walking_speed_pdf(v)
    p = sum(WALK_WEIGHTS[j] * exp(gamma_logpdf(v, WALK_SHAPES[j], WALK_SCALES[j], WALK_LOGGAMMA_SHAPES[j])) for j in 1:2)
    return (1 - TAIL_WEIGHT) * p + TAIL_WEIGHT * exp(gamma_logpdf(v, TAIL_SHAPE, TAIL_SCALE, 0.0))
end

"""
    step_kernels(width) -> (stopped, walking)

The displacement over one step in each state, as `(offsets, logp)` in grid px, each normalised over
its offsets; `width` is the target's width in grid px. A grid position is uncertain by a uniform
±½ px on each axis, so the stopped σ is widened by √(1/6) px, and a walking displacement `d` is
evaluated at √(d² + 1/6) px. The walking density is over the plane: `p(v) / 2πd`.
"""
function step_kernels(width)
    σ = sqrt((STOP_SIGMA * width)^2 + 1 / 6)
    rs = max(1, ceil(Int, 3σ))
    stopped = [(dr, dc) for dc in -rs:rs for dr in -rs:rs if dr^2 + dc^2 <= rs^2]
    ps = [exp(-(dr^2 + dc^2) / 2σ^2) for (dr, dc) in stopped]
    rw = ceil(Int, WALK_REACH * STEP_SECONDS * width)
    walking = [(dr, dc) for dc in -rw:rw for dr in -rw:rw if dr^2 + dc^2 <= rw^2]
    pw = map(walking) do (dr, dc)
        d = sqrt(dr^2 + dc^2 + 1 / 6)
        walking_speed_pdf(d / width / STEP_SECONDS) / (2π * d)
    end
    return (stopped, Float32.(log.(ps ./ sum(ps)))), (walking, Float32.(log.(pw ./ sum(pw))))
end

# One kernel pass: out[x] = max over offsets o of src[x - o] + logp[o] (minus the no-return cost of
# the move, when `return_cost > 0`), and the arg-max offset into `bp`, negated when the source came
# from the other state (`switched`).
function kernel_pass!(out, bp, K, src, switched, (offsets, logp), rmap, return_cost)
    R, C = size(src)
    tforeach(1:C) do c
        for r in 1:R
            best, arg = -Inf32, 0
            rx = rmap[r, c]
            for j in eachindex(offsets)
                dr, dc = offsets[j]
                rr, cc = r - dr, c - dc
                (1 <= rr <= R && 1 <= cc <= C) || continue
                s = src[rr, cc] + logp[j]
                if return_cost > 0
                    rp = rmap[rr, cc]
                    rp > RETURN_FREE && rp > rx && (s -= return_cost * (rp - rx))
                end
                s > best && ((best, arg) = (s, j))
            end
            out[r, c] = best
            bp[r, c, K] = arg > 0 && switched[r - offsets[arg][1], c - offsets[arg][2]] ? -arg : arg
        end
    end
    return out
end

# What every step pays for where it lands, and the last step for where it ends, given the arena.
arena_costs(_, ::Missing) = (0.0f0, 0.0f0)
function arena_costs(d, arena::Float64)
    outside = Float32(OUTSIDE_COST * max(0, d - (arena + OUTSIDE_MARGIN)))
    ending = Float32(-min(EDGE_CAP, EDGE_COST * max(0, abs(d - arena) - EDGE_BAND)))
    return outside, ending
end

function best_path(model::MotionModel, z, za, vol)
    R, C, n = size(z)
    m = max(1, round(Int, STEP_SECONDS / vol.dt))
    e = emission(z, za, m)
    N = size(e, 3)
    stopped, walking = step_kernels(vol.width)
    T = STEP_SECONDS
    a_ss, a_ws = Float32(log1p(-STOP_TO_WALK * T)), Float32(log(WALK_TO_STOP * T))
    a_ww, a_sw = Float32(log1p(-WALK_TO_STOP * T)), Float32(log(STOP_TO_WALK * T))

    r0, c0 = vol.start
    rmap = Float32[hypot(r - r0, c - c0) / vol.width for r in 1:R, c in 1:C]   # widths from the start
    outside = first.(arena_costs.(rmap, model.arena))

    bps = Array{Int32, 3}(undef, R, C, N)   # into stopped: offset index, negative when it came from walking
    bpw = Array{Int32, 3}(undef, R, C, N)   # into walking: same, negative when it came from stopped
    S = fill(-Inf32, R, C)
    W = fill(-Inf32, R, C)
    for ix in anchor_disk(vol, R, C)
        S[ix] = W[ix] = e[ix, 1] + log(0.5f0)
    end
    A, B, Snew, Wnew = similar(S), similar(S), similar(S), similar(S)
    fromW, fromS = falses(R, C), falses(R, C)
    for K in 2:N
        for i in eachindex(A)
            x, y = S[i] + a_ss, W[i] + a_ws
            A[i] = max(x, y)
            fromW[i] = y > x
            x, y = W[i] + a_ww, S[i] + a_sw
            B[i] = max(x, y)
            fromS[i] = y > x
        end
        kernel_pass!(Snew, bps, K, A, fromW, stopped, rmap, 0.0f0)
        kernel_pass!(Wnew, bpw, K, B, fromS, walking, rmap, Float32(RETURN_COST))
        top = max(maximum(Snew), maximum(Wnew))
        ek = view(e, :, :, K)
        @. S = Snew + ek - outside - top
        @. W = Wnew + ek - outside - top
    end
    ending = last.(arena_costs.(rmap, model.arena))
    Sf, Wf = S .+ ending, W .+ ending
    steps = backtrack_states(bps, bpw, stopped[1], walking[1], Sf, Wf, argmax(max.(Sf, Wf)))
    return to_samples(steps, m, n)
end

# The best step path ending at `last`, one grid index per step.
function backtrack_states(bps, bpw, offs_s, offs_w, Sf, Wf, last)
    N = size(bps, 3)
    r, c = last[1], last[2]
    walking = Wf[r, c] >= Sf[r, c]
    out = Vector{NTuple{2, Float64}}(undef, N)
    for K in N:-1:1
        out[K] = (r, c)
        K == 1 && break
        j = walking ? bpw[r, c, K] : bps[r, c, K]
        o = (walking ? offs_w : offs_s)[abs(j)]
        r, c = r - o[1], c - o[2]
        j < 0 && (walking = !walking)
    end
    return out
end

# The step path at every sample: linear between the steps' centres, the first and last held.
function to_samples(steps, m, n)
    centres = [((K - 1) * m + 1 + min(n, K * m)) / 2 for K in eachindex(steps)]
    return map(1:n) do k
        a = clamp(searchsortedlast(centres, k), 1, length(steps))
        b = min(a + 1, length(steps))
        t = b == a ? 0.0 : clamp((k - centres[a]) / (centres[b] - centres[a]), 0, 1)
        ((1 - t) * steps[a][1] + t * steps[b][1], (1 - t) * steps[a][2] + t * steps[b][2])
    end
end

# Localise each path point on the uncapped score: the z-weighted centroid of the 3×3 around the
# strongest pixel within one target width. The path chooses WHICH object; this chooses where on it,
# which the cap flattens away on a target many pixels wide.
function refine(z, p, width)
    R, C, _ = size(z)
    rad = max(1, round(Int, width))
    return map(eachindex(p)) do k
        r0, c0 = round.(Int, p[k])
        best, br, bc = -Inf32, r0, c0
        for c in max(1, c0 - rad):min(C, c0 + rad), r in max(1, r0 - rad):min(R, r0 + rad)
            (r - r0)^2 + (c - c0)^2 <= rad^2 && z[r, c, k] > best && ((best, br, bc) = (z[r, c, k], r, c))
        end
        w = sr = sc = 0.0
        for c in max(1, bc - 1):min(C, bc + 1), r in max(1, br - 1):min(R, br + 1)
            x = max(0.0, z[r, c, k])
            w += x
            sr += x * r
            sc += x * c
        end
        w > 0 ? (sr / w, sc / w) : (float(br), float(bc))
    end
end

# ---- out of the grid -------------------------------------------------------------------------

# AprilTag: a grid index is a reference index (`full_index`), and the fixed metric map takes it to
# ground, as the online tracker's `img_to_ground`. Every sample has a position, an unregistered one
# included: the path is in reference space and runs through it, so only that sample's pixels were
# unusable, never where the path puts it. The element type admits `missing` all the same, so a run's
# track has one type whichever tracker made it.
function grid_coordinates(p, rectification::ApriltagRectification, tuning)
    ds = tuning.downscale
    return Union{Missing, GroundXY}[img_to_ground(rectification.reference.M, full_index.(q, ds)) for q in p]
end

# Otherwise: a grid index is a display index (`full_index`), and the column crosses to stored
# through `aspect` — a stored index, as the online tracker's `detect` returns.
function grid_coordinates(p, _, tuning)
    ds, sar = tuning.downscale, Float64(tuning.aspect)
    return RowCol[RowCol(full_index(r, ds), (full_index(c, ds) - 1) / sar + 1) for (r, c) in p]
end

# The same return as the online `track` on the same rectification, so a run's track has one type
# whichever tracker made it.
real_coordinates(coords, rectification::ApriltagRectification) = _apply_image2real(rectification.image2real, coords)
real_coordinates(coords, ::Nothing) = map(from_index, coords)
real_coordinates(coords, rectification) = map(rectification.image2real, map(from_index, coords))

# ---- the diagnostic --------------------------------------------------------------------------

# The run diagnostic clip, from the grid frames the path was found on: the existing writer and
# scenes, each told how to read a grid frame. AprilTag: the scene's image → ground map for a grid
# frame is the metric map after grid → reference, which in 0-based pixels is `(g + ½)/ds − ½`
# (`full_index`, less the one each side of it).
function write_diagnostic(file, vol, p, coords, tuning, rectification::ApriltagRectification)
    s = 1 / tuning.downscale
    grid2ref = SMatrix{3, 3, Float64, 9}(s, 0, 0, 0, s, 0, s / 2 - 1 / 2, s / 2 - 1 / 2, 1)   # column-major
    H = rectification.reference.M * grid2ref
    fps = effective_fps(tuning.native_fps, tuning.sample_fps)
    diagnose_apriltag(file, rectification, tuning.darker_target, fps) do dia
        each_sample(vol, dia) do k, t, frame
            dia(t, frame, coords[k], H)
        end
    end
    return
end

# Otherwise: the rectified scene of a rectification whose stored pixel IS the grid pixel (below), or
# the raw scene sized to the grid.
function write_diagnostic(file, vol, p, _, tuning, rectification)
    fps = effective_fps(tuning.native_fps, tuning.sample_fps)
    diagnose(file, tuning.darker_target, on_grid(rectification, tuning), fps) do dia
        update_ratio!(dia, size(first(vol.frames)))
        each_sample(vol, dia) do k, t, frame
            dia(t, frame, p[k])
        end
    end
    return
end

# Every sample, labelled with its segment number and file time.
function each_sample(f, vol, dia)
    k = 0
    for (segment, ts) in enumerate(vol.tss)
        begin_segment!(dia, segment)
        for t in ts
            k += 1
            f(k, t, reinterpret(Gray{N0f8}, vol.frames[k]))
        end
    end
    return
end

# The rectification seen from the grid: stored 0-based (row, col) → grid 0-based is
# `((row + ½)·ds − ½, (col·sar + ½)·ds − ½)` (`grid_index`, less the one each side of it), so
# composing it in makes `RectifiedScene` sample the grid frame and place a grid index.
on_grid(::Nothing, _) = nothing
function on_grid(r::StaticRectification, tuning)
    ds, sar = tuning.downscale, Float64(tuning.aspect)
    g = AffineMap(SDiagonal(ds, ds * sar), SVector(ds / 2 - 1 / 2, ds / 2 - 1 / 2))
    return StaticRectification(r.image2real ∘ inv(g), g ∘ r.real2image, r.ratio, r.width, r.height)
end

# ---- the entry point -------------------------------------------------------------------------

"""
    track_whole_run(segments::Vector{Segment}, tuning::Tuning, rectification, diagnostic_file)

The whole-run tracker: `track`'s arguments and return, one path over the whole run. Every segment
is read into memory on the grid (`tuning.downscale`, `tuning.sample_fps`), one background is the
median over all of them, and the path is the best one through them all, from the first segment's
`start_location`. A segment boundary is an ordinary step: later segments' start locations are not
read.

With an `ApriltagRectification` the path follows the fitted motion model with the no-return prior,
and, when `tuning.arena_radius` is given, the arena prior (see `MotionModel`); otherwise a
per-sample step cost (`NoMotionModel`). Coordinates are those `track` returns on the same
rectification: real-world, or stored `(row, col)` pixels without one. Unlike the online tracker's,
an AprilTag track has a position at every sample, unregistered ones included (`grid_coordinates`).

Memory: the grid volume (one byte per grid pixel per sample, ~0.07 GB per minute of drone footage at
the defaults), its score (four bytes) and the path's back-pointers.
"""
function track_whole_run(segments::Vector{Segment}, tuning::Tuning, rectification, diagnostic_file)
    vol = read_run(segments, tuning, rectification)
    p = whole_run_path(vol, path_model(rectification, tuning), tuning.darker_target)
    coords = grid_coordinates(p, rectification, tuning)
    isnothing(diagnostic_file) || write_diagnostic(diagnostic_file, vol, p, coords, tuning, rectification)
    return (_concat_timestamps(vol.tss), real_coordinates(coords, rectification))
end

"""
    fastest_second(ts, coords) -> Float64

The largest distance, in `coords`' unit, covered over one second of a track (the nearest whole
number of samples to one second), skipping `missing` points; 0 for a track shorter than that.
"""
function fastest_second(ts, coords)
    lag = max(1, round(Int, 1 / step(ts)))
    fastest = 0.0
    for i in 1:(length(coords) - lag)
        a, b = coords[i], coords[i + lag]
        (ismissing(a) || ismissing(b)) && continue
        fastest = max(fastest, norm(b - a) / (lag * step(ts)))
    end
    return fastest
end
