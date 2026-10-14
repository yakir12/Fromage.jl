# THE WHOLE-RUN TRACKER
#
# The online tracker (`track`) decides frame by frame. This one holds the whole run in memory and
# finds one path over all of it: every segment is read, registered and reduced into one volume, in
# csv order, and the path is the best one through that volume under a model of how the target moves
# and how it looks. Selected per run by `Tuning.whole_run`; the seam is `VerifyRuns.track(r::Run, …)`.
#
#   read_run → background → score_dark → anchor_contrast → large_foreground → penalise_large_blobs!
#     → best_path → refine
#
# Large foreground (#412) is where an experimenter, or their shadow, is: the path pays to enter it
# and a large blob inside it scores less, so the track does not leave the target with a person.
#
# The tracker then reviews its own track (#418, `whole_run_review`): how fast its fastest second is,
# how little its path beats any path that strays from it (the anchored margin, from a backward pass
# over the same evidence), and how far it moves when the background is built from half the run. A run
# any of the three flags is one to check by eye; `main` writes them to `review/flags.csv`.
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

# Large foreground (#412): an experimenter, or their shadow, is a large region that differs from the
# whole-run background, brighter or darker; the target is a few pixels. A grid pixel is large
# foreground when it differs from the background by at least FG_GREY grey levels and its 4-connected
# component of such pixels covers at least FG_AREA_W2 square target widths; the mask is then dilated
# by FG_DILATE_W widths. Inside it the path pays twice: a move of at least ENTRY_MIN_W widths that
# enters it costs ENTRY_KAPPA × the target's own contrast, and a z blob (4-connected, z ≥ ½ the
# target's contrast) larger than SIZE_KAPPA square widths loses SIZE_LAMBDA × that contrast on its
# pixels inside it. FG_GREY is absolute grey levels, not a fraction of anything.
const FG_GREY = 20.0
const FG_AREA_W2 = 25.0
const FG_DILATE_W = 1.0
const ENTRY_KAPPA = 1.0
const ENTRY_MIN_W = 1.0
const SIZE_KAPPA = 4.0
const SIZE_LAMBDA = 1.0

# The review (#418, rule R1 of #413): three signals per run, and the run is flagged for review when
# any of them is. `fast`: the fastest second covers more than SUSPECT_SPEED target widths, on
# AprilTag footage only; elsewhere `target_width` is a default rather than the target's real width.
# The fitted walk's p99.9 is 1.6 widths/s; every whole-run failure among 157 drone runs had a fastest
# second of 3.5–4 (#376). `ambiguous`: the minimum anchored margin is below its video type's cut
# (MARGIN_CUTS). `unstable`: the track is more than RIVAL_WIDTHS widths from the path re-solved on a
# background median of half the run, for UNSTABLE_SECONDS or longer.
const SUSPECT_SPEED = 3.0
const RIVAL_WIDTHS = 3.0
const UNSTABLE_SECONDS = 60.0

# The margin cut of each video type (CONTEXT, "Video type"), in nats: the k-th lowest `margin_min`
# among that type's eye-passed dev runs (k such that 1% of them fall below it), fitted on candidate D
# in the research (`prototypes/413/margin_cuts.txt`) and frozen. The values are those margins exactly,
# Float32 as the margin is: the issue's two-decimal roundings flag two more passes (DECISIONS, "R1").
# Tripod outdoor sand mirror had no passes left to fit on, and borrows the pooled cut of every
# non-drone pass, which is also what a blank video type gets off AprilTag footage.
const POOLED_MARGIN_CUT = 2.87998f0
const MARGIN_CUTS = (
    "drone" => 1.0039139f0,
    "tripod outdoor plywood" => 1.0799866f0,
    "static outdoor sand mirror" => 15.119993f0,
    "tripod outdoor sand mirror" => POOLED_MARGIN_CUT,
    "indoor LED" => 14.76001f0,
    "indoor infrared" => 108.72479f0,
)
const VIDEO_TYPES = first.(MARGIN_CUTS)

# Each segment's sample times: the `StepRangeLen` a `range` of `Float64`s is, as the online
# tracker's `track` collects them.
const SampleTimes = StepRangeLen{Float64, Base.TwicePrecision{Float64}, Base.TwicePrecision{Float64}, Int64}

# ---- the volume ------------------------------------------------------------------------------

"""
    RunVolume

A whole run on the grid: `frames[k]` is sample `k`, `has[k]` whether it was registered (always
true without AprilTags; an unregistered sample borrows the nearest registration and scores 0),
`Hinvs[k]` its inverse registration, reference → raw frame (meaningful only where `has[k]`, and
empty without AprilTags; it is how a sample's display pixel is found, #401), and `tss` each
segment's file times, the segments' samples following one another in `frames`. `start` is the
start location as a grid index, `anchor` the radius around it the target starts within, `width`
the target's width and `dt` the seconds between samples — all on the grid.
"""
struct RunVolume
    frames::Vector{Matrix{UInt8}}
    has::Vector{Bool}
    Hinvs::Vector{SMatrix{3, 3, Float64, 9}}
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

function RunVolume(frames, has, Hinvs, tss, start_location, to_grid, tuning)
    sz = size(first(frames))
    start, radius = anchor(start_location, to_grid, tuning, sz)
    # a start off the grid anchors at the nearest grid pixel
    start = (clamp(start[1], 1, sz[1]), clamp(start[2], 1, sz[2]))
    dt = 1 / effective_fps(tuning.native_fps, tuning.sample_fps)
    return RunVolume(frames, has, Hinvs, tss, start, radius, tuning.downscale * tuning.target_width, dt)
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
    frames, has, Hinvs = Matrix{UInt8}[], Bool[], SMatrix{3, 3, Float64, 9}[]
    tss = Vector{SampleTimes}(undef, length(segments))
    seeds = map(enumerate(segments)) do (i, s)
        video(s.file, tuning.native_fps, tuning.sample_fps, s.start, s.stop, 1.0, tuning.aspect) do vid
            tss[i] = range(s.start; step = 1 / vid.sample_fps, length = vid.nframes)
            read_registered!(frames, has, Hinvs, vid, rectification, ds, sz, s.file)
        end
    end
    seedR = first(seeds)
    # the start location is a pixel of the run's first frame; it crosses into the reference
    # through that segment's first registration, as the online tracker's `apriltag_guess` does
    function to_grid((x, y))
        p = to_index(apply_h(seedR, SVector(stored_x(x, tuning.aspect), Float64(y))))
        return (grid_index(p[2], ds), grid_index(p[1], ds))
    end
    return RunVolume(frames, has, Hinvs, tss, first(segments).start_location, to_grid, tuning)
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
    return RunVolume(frames, has, SMatrix{3, 3, Float64, 9}[], tss, first(segments).start_location, to_grid, tuning)
end

# One segment's samples, registered and reduced onto the grid, with the inverse registration each was
# warped through; returns the segment's first registration. A sample before the first registration
# is held raw until it arrives, and one without all its tags borrows the last registration (and is
# recorded as unregistered).
function read_registered!(frames, has, Hinvs, vid, rectification, ds, sz, file)
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
                        push!(Hinvs, Hinv)
                    end
                    empty!(pending)
                end
            end
            if seeded
                push!(frames, grid_frame(vid.img, RegisteredWarp(1.0, [Hinv]), sz, ds))
                push!(Hinvs, Hinv)
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

# The target's own contrast: the median, over the first second's registered samples, of the peak z
# inside the anchor disk. An unregistered sample scores 0 everywhere, so counting one would say the
# target has no contrast; with most of the first second unregistered the median was 0, every dark
# object then scored below bare ground, and the path left the target for the whole run (#406). With
# none of the first second registered, the first registered sample stands in, still measured in the
# anchor disk: the target walks ~0.6 widths/s, so a second or two later it is still inside it. A run
# with no registered sample at all never gets here (`read_registered!` refuses it); the 0 is defensive.
function anchor_contrast(z, vol)
    disk = anchor_disk(vol, size(z, 1), size(z, 2))
    ks = filter(k -> vol.has[k], 1:min(size(z, 3), max(1, round(Int, 1 / vol.dt))))
    if isempty(ks)
        first_registered = findfirst(vol.has)
        isnothing(first_registered) && return 0.0f0
        push!(ks, first_registered)
    end
    peaks = [maximum(z[ix, k] for ix in disk) for k in ks]
    return Float32(middle!(peaks))
end

# ---- large foreground ------------------------------------------------------------------------

# Calls `f(component)` on every 4-connected component of the pixels `i` where `inside(i)`, as a
# vector of linear indices (reused between calls). `seen`, `stack` and `comp` are the caller's.
function foreach_component(f, inside, seen::BitMatrix, stack::Vector{Int}, comp::Vector{Int})
    R, C = size(seen)
    fill!(seen, false)
    for i in eachindex(seen)
        (seen[i] || !inside(i)) && continue
        seen[i] = true
        empty!(comp)
        push!(stack, i)
        while !isempty(stack)
            j = pop!(stack)
            push!(comp, j)
            r, c = mod1(j, R), cld(j, R)
            for (rr, cc) in ((r + 1, c), (r - 1, c), (r, c + 1), (r, c - 1))
                (1 <= rr <= R && 1 <= cc <= C) || continue
                q = rr + (cc - 1) * R
                (seen[q] || !inside(q)) && continue
                seen[q] = true
                push!(stack, q)
            end
        end
        f(comp)
    end
    return
end

# `L` |= `src` dilated by a square of half-side `d` grid px, as two separable passes through `tmp`.
function dilate!(L::BitMatrix, src::BitMatrix, tmp::BitMatrix, d)
    R, C = size(L)
    fill!(tmp, false)
    for c in 1:C, r in 1:R
        src[r, c] || continue
        tmp[max(1, r - d):min(R, r + d), c] .= true
    end
    for c in 1:C, r in 1:R
        tmp[r, c] || continue
        L[r, max(1, c - d):min(C, c + d)] .= true
    end
    return L
end

"""
    large_foreground(vol, bg) -> Vector{BitMatrix}

Each sample's large foreground (see `FG_GREY`): the pixels that differ from the background `bg` by
at least `FG_GREY` grey levels, in 4-connected components of at least `FG_AREA_W2` square target
widths, dilated by `FG_DILATE_W` widths. A pixel that is 0 in the frame or the background is off
the footprint (an AprilTag sample's warp reads 0 off the raw frame): it never counts toward a
component, though the dilation may still reach it.
"""
function large_foreground(vol::RunVolume, bg)
    R, C = size(bg)
    amin = ceil(Int, FG_AREA_W2 * vol.width^2)
    d = round(Int, FG_DILATE_W * vol.width)
    out = [falses(R, C) for _ in vol.frames]
    @tasks for k in eachindex(vol.frames)
        @local begin
            big, seen, tmp = falses(R, C), falses(R, C), falses(R, C)
            stack, comp = Int[], Int[]
        end
        frame = vol.frames[k]
        differs = i -> frame[i] != 0 && bg[i] != 0 && abs(Float32(frame[i]) - bg[i]) >= Float32(FG_GREY)
        fill!(big, false)
        foreach_component(differs, seen, stack, comp) do component
            length(component) >= amin && (big[component] .= true)
        end
        d > 0 ? dilate!(out[k], big, tmp, d) : copyto!(out[k], big)
    end
    return out
end

# The size term: at every sample, each z blob (4-connected, z ≥ ½ `za`) larger than SIZE_KAPPA
# square widths loses SIZE_LAMBDA × `za` on its pixels inside large foreground `fg`. In place: the
# path and `refine` both see the lowered score.
function penalise_large_blobs!(z, fg, za, width)
    R, C, n = size(z)
    thr = 0.5f0 * za
    amax = SIZE_KAPPA * width^2
    pen = Float32(SIZE_LAMBDA) * za
    @tasks for k in 1:n
        @local begin
            seen = falses(R, C)
            stack, comp = Int[], Int[]
        end
        zk, fgk = view(z, :, :, k), fg[k]
        foreach_component(i -> zk[i] >= thr, seen, stack, comp) do component
            length(component) > amax || return
            for j in component
                fgk[j] && (zk[j] -= pen)
            end
        end
    end
    return z
end

# Whether each offset is long enough to pay the entry cost.
long_moves(offsets, width) = [hypot(dr, dc) >= ENTRY_MIN_W * width for (dr, dc) in offsets]

# The motion model's step masks: the union of its `m` samples' masks.
function step_foreground(fg, m)
    m == 1 && return fg
    return [reduce(.|, fg[((K - 1) * m + 1):min(end, K * m)]) for K in 1:cld(length(fg), m)]
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
    whole_run_path(vol, model, darker_target, ks = eachindex(vol.frames)) -> Vector{NTuple{2, Float64}}

The target's grid index at every sample of `vol`: the best path under `model`, each point then
localised on the uncapped score. Inside large foreground (`large_foreground`) the score of a large
blob is lowered and entering it costs the path (#412). The background is the median over the
samples `ks`: all of them, but for the review's background-half solves (`whole_run_review`).
"""
whole_run_path(vol::RunVolume, model, darker_target, ks = eachindex(vol.frames)) =
    first(solve(vol, model, darker_target, ks, nothing))

# Asks `best_path` for the anchored margin too.
struct WithMargin end

# The path, and with `margin = WithMargin()` the anchored margin at each of its steps (`nothing`
# without it). Every sample is scored and masked against the one background over `ks`.
function solve(vol::RunVolume, model, darker_target, ks, margin::Union{Nothing, WithMargin})
    bg = background(vol.frames[ks])
    z = score_dark(vol, bg, darker_target)
    return solve!(z, large_foreground(vol, bg), vol, model, margin)
end

# The path on the score `z`, given each sample's large foreground `fg`; lowers `z` by the size term.
# With no large foreground anywhere this is the tracker before #412 exactly, which is how the tests
# compare the two.
whole_run_path!(z, fg, vol::RunVolume, model) = first(solve!(z, fg, vol, model, nothing))

function solve!(z, fg, vol::RunVolume, model, margin::Union{Nothing, WithMargin})
    za = anchor_contrast(z, vol)   # the target's own contrast, before the size term lowers z
    penalise_large_blobs!(z, fg, za, vol.width)
    nodes, m = best_path(model, z, za, vol, fg, margin)
    return refine(z, to_samples(nodes, step_samples(model, vol), size(z, 3)), vol.width), m
end

# Where `best_path` keeps its forward messages, for the margin's backward pass to complete into
# max-marginals: one array per state and step. Each model allocates its own (`WithMargin`), so a
# store never meets the other model's path.
best_path(model, z, za, vol, fg, ::WithMargin) = best_path(model, z, za, vol, fg, forward_store(model, z, vol))
forward_store(::NoMotionModel, z, _) = similar(z)
function forward_store(model::MotionModel, z, vol)
    R, C, n = size(z)
    N = cld(n, step_samples(model, vol))
    return (Array{Float32, 3}(undef, R, C, N), Array{Float32, 3}(undef, R, C, N))
end

# The samples per path step: a second's worth with the motion model, one without.
step_samples(::MotionModel, vol) = max(1, round(Int, STEP_SECONDS / vol.dt))
step_samples(::NoMotionModel, _) = 1

# The per-pixel ceiling on a sample's score, as a fraction of the target's own contrast: anything at
# least as dark as the target scores the same, so a larger dark thing is no more attractive. A long
# move from outside sample `k`'s large foreground to inside it pays the entry cost `ec`. Returns the
# path, one grid index per sample, and its anchored margin (`no_motion_margin`) when `F` is a store.
function best_path(::NoMotionModel, z, za, vol, fg, F::Union{Nothing, Array{Float32, 3}})
    R, C, n = size(z)
    σ = NO_MOTION_SPEED * vol.width * vol.dt
    reach = max(2, ceil(Int, 4σ))
    offsets = [(dr, dc) for dc in -reach:reach for dr in -reach:reach if dr^2 + dc^2 <= reach^2]
    cost = Float32[(dr^2 + dc^2) / 2σ^2 for (dr, dc) in offsets]
    long = long_moves(offsets, vol.width)
    ec = Float32(ENTRY_KAPPA) * za
    cap = Float32(NO_MOTION_CAP * za)
    back = Array{Int32, 3}(undef, R, C, n)
    δ = fill(-Inf32, R, C)
    for ix in anchor_disk(vol, R, C)
        δ[ix] = min(z[ix, 1], cap)
    end
    keep!(F, δ, 1)
    δnext = similar(δ)
    for k in 2:n
        fgk = fg[k]
        tforeach(1:C) do c
            for r in 1:R
                best, arg = -Inf32, Int32(0)
                into = fgk[r, c]
                for (j, (dr, dc)) in enumerate(offsets)
                    rr, cc = r - dr, c - dc
                    (1 <= rr <= R && 1 <= cc <= C) || continue
                    s = δ[rr, cc] - cost[j]
                    (into && long[j] && !fgk[rr, cc]) && (s -= ec)
                    s > best && ((best, arg) = (s, Int32(j)))
                end
                δnext[r, c] = best + min(z[r, c, k], cap)
                back[r, c, k] = arg
            end
        end
        δ .= δnext .- maximum(δnext)
        keep!(F, δ, k)
    end
    p = backtrack(back, offsets, argmax(δ))
    return p, no_motion_margin(F, p, z, vol, fg, offsets, cost, long, cap, ec)
end

# Keep step `k`'s forward message in the store `F`: one array, or the (stopped, walking) pair.
keep!(::Nothing, _, _) = nothing
keep!(F::Array{Float32, 3}, δ, k) = (F[:, :, k] .= δ; nothing)
function keep!((FS, FW)::NTuple{2, Array{Float32, 3}}, (S, W), k)
    FS[:, :, k] .= S
    FW[:, :, k] .= W
    return nothing
end

# THE ANCHORED MARGIN (#418, from the research's linking note #389): at each step of the path, the
# path's score less the best score of any path that satisfies the same anchors (starts in the anchor
# disk, pays the same ending) and is more than RIVAL_WIDTHS target widths from the path at that step.
# Max-marginals give it at every step for one more pass: the forward messages kept in `F`, plus a
# backward pass over the same evidence, with the same entry cost on the same moves. It is a lower
# bound on a disjoint rival's deficit, since the rival may rejoin the path elsewhere. In nats, the
# score's unit, so its scale differs by footage (hence a cut per video type, `MARGIN_CUTS`).

# Without a store there is no margin.
no_motion_margin(::Nothing, _...) = nothing

# β_k(x) = max over offsets o of β_{k+1}(x + o) + score_{k+1}(x + o) − cost(o), less the entry cost
# of a long move from outside sample k + 1's large foreground into it. `F` becomes the max-marginals.
function no_motion_margin(F::Array{Float32, 3}, p, z, vol, fg, offsets, cost, long, cap, ec)
    R, C, n = size(z)
    β = zeros(Float32, R, C)
    βn, src = similar(β), similar(β)
    for k in n:-1:1
        if k < n
            @. src = β + min($view(z, :, :, k + 1), cap)
            no_motion_backward!(βn, src, offsets, cost, fg[k + 1], long, ec)
            β .= βn .- maximum(βn)
        end
        view(F, :, :, k) .+= β
    end
    return margins(F, p, vol.width)
end

# The no-motion forward step run backward: out[x] = max over offsets o of src[x + o] − cost[o], less
# the entry cost of a `long` move from outside `fgK` to inside it.
function no_motion_backward!(out, src, offsets, cost, fgK, long, ec)
    R, C = size(src)
    tforeach(1:C) do c
        for r in 1:R
            best = -Inf32
            from_out = !fgK[r, c]
            for (j, (dr, dc)) in enumerate(offsets)
                rr, cc = r + dr, c + dc
                (1 <= rr <= R && 1 <= cc <= C) || continue
                s = src[rr, cc] - cost[j]
                (from_out && long[j] && fgK[rr, cc]) && (s -= ec)
                best = max(best, s)
            end
            out[r, c] = best
        end
    end
    return out
end

# The margin at each step, from the max-marginals `M` and the path `nodes` (one grid index per step):
# the best of all minus the best more than RIVAL_WIDTHS widths from the path's point.
function margins(M::Array{Float32, 3}, nodes, width)
    R, C, N = size(M)
    rad2 = (RIVAL_WIDTHS * width)^2
    out = Vector{Float32}(undef, N)
    tforeach(1:N) do K
        r0, c0 = nodes[K]
        top, rival = -Inf32, -Inf32
        for c in 1:C, r in 1:R
            v = M[r, c, K]
            top = max(top, v)
            (r - r0)^2 + (c - c0)^2 > rad2 && (rival = max(rival, v))
        end
        out[K] = top - rival
    end
    return out
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
# the move, when `return_cost > 0`, and the entry cost `ec` of a `long` move from outside the step's
# large foreground `fgK` to inside it), and the arg-max offset into `bp`, negated when the source came
# from the other state (`switched`).
function kernel_pass!(out, bp, K, src, switched, (offsets, logp), rmap, return_cost, fgK, long, ec)
    R, C = size(src)
    tforeach(1:C) do c
        for r in 1:R
            best, arg = -Inf32, 0
            rx = rmap[r, c]
            into = fgK[r, c]
            for j in eachindex(offsets)
                dr, dc = offsets[j]
                rr, cc = r - dr, c - dc
                (1 <= rr <= R && 1 <= cc <= C) || continue
                s = src[rr, cc] + logp[j]
                if return_cost > 0
                    rp = rmap[rr, cc]
                    rp > RETURN_FREE && rp > rx && (s -= return_cost * (rp - rx))
                end
                (into && long[j] && !fgK[rr, cc]) && (s -= ec)
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

# Returns the path, one grid index per STEP (`to_samples` spreads it over the samples), and its
# anchored margin (`motion_margin`) when `F` is a store.
function best_path(model::MotionModel, z, za, vol, fg, F::Union{Nothing, NTuple{2, Array{Float32, 3}}})
    R, C, n = size(z)
    m = step_samples(model, vol)
    e = emission(z, za, m)
    N = size(e, 3)
    stopped, walking = step_kernels(vol.width)
    long_s, long_w = long_moves(stopped[1], vol.width), long_moves(walking[1], vol.width)
    ec = Float32(ENTRY_KAPPA) * za
    fgs = step_foreground(fg, m)   # one mask per step
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
    keep!(F, (S, W), 1)
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
        kernel_pass!(Snew, bps, K, A, fromW, stopped, rmap, 0.0f0, fgs[K], long_s, ec)
        kernel_pass!(Wnew, bpw, K, B, fromS, walking, rmap, Float32(RETURN_COST), fgs[K], long_w, ec)
        top = max(maximum(Snew), maximum(Wnew))
        ek = view(e, :, :, K)
        @. S = Snew + ek - outside - top
        @. W = Wnew + ek - outside - top
        keep!(F, (S, W), K)
    end
    ending = last.(arena_costs.(rmap, model.arena))
    Sf, Wf = S .+ ending, W .+ ending
    steps = backtrack_states(bps, bpw, stopped[1], walking[1], Sf, Wf, argmax(max.(Sf, Wf)))
    transitions = (a_ss, a_ws, a_ww, a_sw)
    return steps, motion_margin(F, steps, e, vol, fgs, stopped, walking, long_s, long_w, ec, transitions, rmap, outside, ending)
end

motion_margin(::Nothing, _...) = nothing

# The backward pass of `best_path(::MotionModel, …)`. βS_K(x): the best continuation from (x,
# stopped) at step K, the ending cost included. Moving into stopped at K + 1 uses the stopped kernel;
# into walking, the walking kernel and the no-return cost of the move, as forward; either pays the
# entry cost of a long move into step K + 1's large foreground. `FS` becomes the max-marginals.
function motion_margin(
        (FS, FW)::NTuple{2, Array{Float32, 3}}, steps, e, vol, fgs, stopped, walking, long_s, long_w, ec,
        (a_ss, a_ws, a_ww, a_sw), rmap, outside, ending
    )
    N = size(e, 3)
    βS, βW = copy(ending), copy(ending)
    KS, KW, srcS, srcW = similar(βS), similar(βS), similar(βS), similar(βS)
    for K in N:-1:1
        if K < N
            ek = view(e, :, :, K + 1)
            @. srcS = βS + ek - outside
            @. srcW = βW + ek - outside
            backward_pass!(KS, srcS, stopped, rmap, 0.0f0, fgs[K + 1], long_s, ec)
            backward_pass!(KW, srcW, walking, rmap, Float32(RETURN_COST), fgs[K + 1], long_w, ec)
            @. βS = max(a_ss + KS, a_sw + KW)
            @. βW = max(a_ww + KW, a_ws + KS)
            top = max(maximum(βS), maximum(βW))
            βS .-= top
            βW .-= top
        end
        @. FS[:, :, K] = max(FS[:, :, K] + βS, FW[:, :, K] + βW)
    end
    return margins(FS, steps, vol.width)
end

# `kernel_pass!` run backward: out[x] = max over offsets o of src[x + o] + logp[o], less the no-return
# cost of the move x → x + o and the entry cost of a `long` one from outside `fgK` to inside it.
function backward_pass!(out, src, (offsets, logp), rmap, return_cost, fgK, long, ec)
    R, C = size(src)
    tforeach(1:C) do c
        for r in 1:R
            best = -Inf32
            rx = rmap[r, c]
            from_out = !fgK[r, c]
            for j in eachindex(offsets)
                dr, dc = offsets[j]
                rr, cc = r + dr, c + dc
                (1 <= rr <= R && 1 <= cc <= C) || continue
                s = src[rr, cc] + logp[j]
                if return_cost > 0
                    rp = rmap[rr, cc]
                    rx > RETURN_FREE && rx > rp && (s -= return_cost * (rx - rp))
                end
                (from_out && long[j] && fgK[rr, cc]) && (s -= ec)
                best = max(best, s)
            end
            out[r, c] = best
        end
    end
    return out
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
    m == 1 && return steps
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

# ---- the review (#418) -----------------------------------------------------------------------

"""
    Moment(run_time, segment, file_time)

Where a sample is: its `run_time` (the track csv's `time`), and the `segment` it is in with its
`file_time`, the seconds into that segment's own video file (the diagnostic's label).
"""
struct Moment
    run_time::Float64
    segment::Int
    file_time::Float64
end

# Sample `k`'s moment, given each segment's file times.
function Moment(tss::Vector{SampleTimes}, k::Integer)
    i, segment = k, 1
    while i > length(tss[segment])
        i -= length(tss[segment])
        segment += 1
    end
    return Moment(_concat_timestamps(tss)[k], segment, tss[segment][i])
end

"""
    Signal(value, cut, flagged, moment)

One of a whole-run track's review signals: its `value`, the `cut` it is held to (`missing` where it
is not held to one), whether it is `flagged`, and its `moment` (`missing` when it has none). `T` is
the value's own type: Float32 for the margin, as the path's scores are, Float64 otherwise.
"""
struct Signal{T <: AbstractFloat}
    value::T
    cut::Union{Missing, T}
    flagged::Bool
    moment::Union{Missing, Moment}
end

"""
    Review(fast, ambiguous, unstable)

The whole-run tracker's check on its own track (#418, the research's rule R1): three `Signal`s, and
the run is flagged for review when any of them is (`flagged`). Each one's value and moment:

- `fast`: the fastest second, in target widths, from the start of that second. Held to
  `SUSPECT_SPEED` on AprilTag footage only: elsewhere `target_width` is a default, not the target.
- `ambiguous`: the minimum anchored margin, in nats, where it is lowest. Held to the run's video
  type's cut (`margin_cut`).
- `unstable`: the longest stretch, in seconds, over which the track is more than RIVAL_WIDTHS widths
  from the path re-solved on a background median of only the first half of the run, or of only the
  second (the worse of the two), from the start of that stretch. Held to UNSTABLE_SECONDS.
"""
struct Review
    fast::Signal{Float64}
    ambiguous::Signal{Float32}
    unstable::Signal{Float64}
end

flagged(r::Review) = any(s -> s.flagged, signals(r))

# The cuts, by footage. `fast`'s: on AprilTag footage only.
fast_cut(::MotionModel) = SUSPECT_SPEED
fast_cut(::NoMotionModel) = missing

"""
    margin_cut(video_type, model) -> Float32

The cut `ambiguous` holds the margin to: the video type's (`MARGIN_CUTS`), or for a blank one the
drone cut on AprilTag footage and the pooled non-drone cut otherwise.
"""
function margin_cut(video_type::String, _)
    i = findfirst(p -> first(p) == video_type, MARGIN_CUTS)
    isnothing(i) && throw(ArgumentError("unknown video_type $(repr(video_type)): it is one of $(join(VIDEO_TYPES, ", "))"))
    return last(MARGIN_CUTS[i])
end
margin_cut(::Missing, ::MotionModel) = margin_cut("drone", nothing)
margin_cut(::Missing, ::NoMotionModel) = POOLED_MARGIN_CUT

# Whether `value` trips `cut` in the signal's own direction (`>`, `<`, `>=`); no cut, no flag.
trips(_, _, ::Missing) = false
trips(over, value, cut) = over(value, cut)

"""
    fastest_second(track, width, dt) -> (widths_per_second, sample)

The largest distance `track` covers over one second (the nearest whole number of samples to it),
over `width`, and the sample that second starts at (`missing` for a track shorter than a second).
"""
function fastest_second(track, width, dt)
    lag = max(1, round(Int, 1 / dt))
    fastest, at = 0.0, missing
    for i in 1:(length(track) - lag)
        v = hypot((track[i + lag] .- track[i])...) / (lag * dt)
        v > fastest && ((fastest, at) = (v, i))
    end
    return fastest / width, at
end

"""
    stretch(a, b, width, dt) -> (seconds, sample)

The longest continuous stretch, in seconds, over which tracks `a` and `b` (the same samples, the same
space) are more than RIVAL_WIDTHS × `width` apart, and the sample it starts at (`missing` for none).
"""
function stretch(a, b, width, dt)
    longest, len, at = 0, 0, missing
    for k in eachindex(a, b)
        len = hypot((a[k] .- b[k])...) > RIVAL_WIDTHS * width ? len + 1 : 0
        len > longest && ((longest, at) = (len, k - len + 1))
    end
    return longest * dt, at
end

moment(_, ::Missing) = missing
moment(vol::RunVolume, k::Integer) = Moment(vol.tss, k)

"""
    whole_run_review(vol, model, tuning) -> (path, Review)

The whole-run path over `vol` (`whole_run_path`'s), and its `Review`. On top of the path itself this
costs a backward pass for the margin and two more solves, the background median built from the first
half of the samples and from the second: 3.8× the path alone (median over 61 runs; DECISIONS, "The
whole-run review").
Lengths are compared on the full-resolution track (reference pixels on AprilTag footage, display
ones otherwise) against `tuning.target_width`, as the research measured them.
"""
function whole_run_review(vol::RunVolume, model, tuning::Tuning)
    p, margin = solve(vol, model, tuning.darker_target, eachindex(vol.frames), WithMargin())
    track = full_track(p, tuning.downscale)
    review = Review(
        fast_signal(track, vol, model, tuning), ambiguous_signal(margin, vol, model, tuning),
        unstable_signal(track, vol, model, tuning)
    )
    return p, review
end

# A grid path at full resolution: reference pixels on AprilTag footage, display ones otherwise.
full_track(p, downscale) = [full_index.(g, downscale) for g in p]

function fast_signal(track, vol, model, tuning)
    v, k = fastest_second(track, tuning.target_width, vol.dt)
    cut = fast_cut(model)
    return Signal(v, cut, trips(>, v, cut), moment(vol, k))
end

# The margin is per path step; its moment is the step's first sample.
function ambiguous_signal(margin, vol, model, tuning)
    K = argmin(margin)
    cut = margin_cut(tuning.video_type, model)
    return Signal(margin[K], cut, trips(<, margin[K], cut), moment(vol, (K - 1) * step_samples(model, vol) + 1))
end

# The worse of the two background halves, the first on a tie.
function unstable_signal(track, vol, model, tuning)
    n = length(track)
    halves = (1:max(1, n ÷ 2), min(n, n ÷ 2 + 1):n)
    a, b = map(halves) do ks
        stretch(track, full_track(whole_run_path(vol, model, tuning.darker_target, ks), tuning.downscale), tuning.target_width, vol.dt)
    end
    v, k = first(a) >= first(b) ? a : b
    return Signal(v, UNSTABLE_SECONDS, trips(>=, v, UNSTABLE_SECONDS), moment(vol, k))
end

"The review's three signals by name, in `flags.csv`'s order."
signals(r::Review) = (; r.fast, r.ambiguous, r.unstable)

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

# The track's display pixels (#401). AprilTag: each sample's reference index back in its own raw
# frame, through its own registration (`raw_display`), so an unregistered sample has none — though
# it has a position (`grid_coordinates`). Otherwise the stored pixels `real_coordinates` maps, as
# display ones, so the two columns of a row are one sample however far `sar` is from 1.
function display_coordinates(p, _, vol, rectification::ApriltagRectification, tuning)
    ds = tuning.downscale
    return Union{Missing, SVector{2, Float64}}[
        vol.has[k] ? raw_display(vol.Hinvs[k], full_index.(p[k], ds), tuning.aspect) : missing for k in eachindex(p)
    ]
end
display_coordinates(_, coords, _, _, tuning) = display_pixels(map(from_index, coords), tuning.aspect)

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
rectification: real-world, or stored `(row, col)` pixels without one; and `pixels`, the display
pixels `track` returns too. Unlike the online tracker's, an AprilTag track has a position at every
sample, unregistered ones included (`grid_coordinates`), though only a registered one has a pixel.

The return is `track`'s three, `(ts, coords, pixels)`, and a fourth: the track's `Review`, whether
it should be checked by eye (#418). So `ts, coords, pixels = …` reads either tracker's return.

Memory: the grid volume (one byte per grid pixel per sample, ~0.07 GB per minute of drone footage at
the defaults), its score (four bytes), its large foreground (one bit) and the path's back-pointers,
and for the review's margin the path's forward messages: four bytes per grid pixel per step, a
second's worth of samples on AprilTag footage and one sample elsewhere.
"""
function track_whole_run(segments::Vector{Segment}, tuning::Tuning, rectification, diagnostic_file)
    vol = read_run(segments, tuning, rectification)
    p, review = whole_run_review(vol, path_model(rectification, tuning), tuning)
    coords = grid_coordinates(p, rectification, tuning)
    pixels = display_coordinates(p, coords, vol, rectification, tuning)
    isnothing(diagnostic_file) || write_diagnostic(diagnostic_file, vol, p, coords, tuning, rectification)
    return (_concat_timestamps(vol.tss), real_coordinates(coords, rectification), pixels, review)
end
