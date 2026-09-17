# PROTOTYPE — THROWAWAY. Answers Fromage.jl issue #283 (wayfinder map #280).
#
# One pseudo-random trial: draw a camera and a board from the #281 envelope, render the waved-board
# frames, the flat extrinsic frame and the arena-with-two-dots frame, encode them losslessly,
# build `from_checkerboard` and `from_extrinsic`, detect the dots with a centroid of its own, map
# them through `image2real`, and print the measured distance beside the true one.
#
# Not production code: no tests, no error handling, no abstractions, one file, prints everything.
# Run:  JULIA_NUM_THREADS=auto julia --project=test <this file> [seed ...]

using LinearAlgebra: norm, cross, normalize, ⋅
using Statistics: median, mean
using Printf: @printf, @sprintf
using Random: Xoshiro                     # prototype only; the real module uses StableRNGs (#280)
using StaticArrays: SVector, SMatrix, SA
using FFMPEG: FFMPEG
using Fromage: Fromage
using Fromage.Rectifications: from_checkerboard, from_extrinsic, get_corners

const V3 = SVector{3, Float64}

# ---------------------------------------------------------------------------
# The trial: everything drawn from one seed, inside the #281 envelope.
# ---------------------------------------------------------------------------

const RESOLUTIONS = [(1920, 1080), (1080, 1920), (720, 576)]
const SARS = [1 // 1, 16 // 15, 64 // 45, 10 // 11]

function draw_trial(seed; sar_override = nothing)
    rng = Xoshiro(seed)
    w, h = rand(rng, RESOLUTIONS)
    sar = something(sar_override, rand(rng, SARS))
    wd = w * float(sar)                       # display width in square pixels
    fov = deg2rad(60 + 60 * rand(rng))        # 60°–120°
    f = (wd / 2) / tan(fov / 2)
    cx = wd / 2 + 0.03wd * (rand(rng) - 0.5)  # principal point a few % off centre
    cy = h / 2 + 0.03h * (rand(rng) - 0.5)
    k1 = -0.3 + 0.35 * rand(rng)              # −0.3 … +0.05
    k = (k1, k1 / 10 * (2rand(rng) - 1), k1 / 100 * (2rand(rng) - 1))
    arena_r = (100 + 100 * rand(rng)) / 2     # arena 100–200 cm across
    height = 100 + 200 * rand(rng)            # camera 1–3 m up
    tilt = deg2rad(30 * rand(rng))            # 0°–30° off nadir
    az = 2π * rand(rng)
    roll = deg2rad(30 * (rand(rng) - 0.5))
    aim = arena_r * 0.25 * rand(rng) * SVector(cos(2π * rand(rng)), sin(2π * rand(rng)))
    n_corners = (rand(rng, 5:9), rand(rng, 7:13))
    checker = 2 + 3 * rand(rng)               # 2–5 cm squares
    dot_r = (1 + 2 * rand(rng)) / 2           # dots 1–3 cm across
    sep = 10 + (1.6arena_r - 10) * rand(rng)  # 10 cm … most of the arena
    return (; seed, w, h, sar, wd, fov, f, cx, cy, k, arena_r, height, tilt, az, roll,
        aim, n_corners, checker, dot_r, sep, rng)
end

# Camera: world → display pixels. Pose from height/tilt/azimuth/roll, aimed at `aim`.
function camera_pose(t)
    A = V3(t.aim[1], t.aim[2], 0)
    C = A + V3(t.height * tan(t.tilt) * cos(t.az), t.height * tan(t.tilt) * sin(t.az), t.height)
    fwd = normalize(A - C)
    ref = abs(fwd[3]) > 0.99 ? V3(0, 1, 0) : V3(0, 0, 1)
    right0 = normalize(cross(ref, fwd))
    down0 = cross(fwd, right0)
    cr, sr = cos(t.roll), sin(t.roll)
    right = cr * right0 + sr * down0
    down = -sr * right0 + cr * down0
    R = SMatrix{3, 3, Float64}(right[1], down[1], fwd[1], right[2], down[2], fwd[2], right[3], down[3], fwd[3])
    return R, C
end

distortion_factor(r2, k) = 1 + k[1] * r2 + k[2] * r2^2 + k[3] * r2^3

# Forward model: world point → 0-based STORED (row, col), or nothing if behind the camera.
function project(t, R, C, P::V3)
    p = R * (P - C)
    p[3] <= 1.0e-6 && return nothing
    x, y = p[1] / p[3], p[2] / p[3]
    g = distortion_factor(x^2 + y^2, t.k)
    u = t.cx + t.f * x * g                    # display x
    v = t.cy + t.f * y * g                    # display y
    return SVector(v, u / float(t.sar))       # stored (row, col), 0-based
end

# Inverse radial model, on the monotone branch only. r_d = r_u * factor(r_u²); bisect for r_u.
# Fold guard: past the first stationary point of r_d(r_u) the model is not invertible, and a
# fixed-point iteration silently returns garbage there (#282 measured OpenCV doing exactly that).
function fold_radius(k)
    dr(ru) = 1 + 3k[1] * ru^2 + 5k[2] * ru^4 + 7k[3] * ru^6
    ru = 0.0
    while ru < 8.0
        dr(ru) <= 0 && return ru
        ru += 0.005
    end
    return 8.0
end

function undistort_radius(rd, k, rmax)
    rd <= 0 && return 0.0
    lo, hi = 0.0, rmax
    rd_at(ru) = ru * distortion_factor(ru^2, k)
    rd > rd_at(rmax) && return NaN            # outside the invertible field
    for _ in 1:60
        mid = (lo + hi) / 2
        rd_at(mid) < rd ? (lo = mid) : (hi = mid)
    end
    return (lo + hi) / 2
end

# The world-space ray through a 0-based stored pixel coordinate. `nothing` past the fold.
function pixel_ray(t, R, C, rowc, colc, rmax)
    xd = (colc * float(t.sar) - t.cx) / t.f
    yd = (rowc - t.cy) / t.f
    rd = hypot(xd, yd)
    ru = undistort_radius(rd, t.k, rmax)
    isnan(ru) && return nothing
    sc = rd == 0 ? 1.0 : ru / rd
    return normalize(R' * V3(xd * sc, yd * sc, 1))
end

# ---------------------------------------------------------------------------
# The scene, as textures on planes. Board coords: internal corner (i, j) at (i, j) * checker.
# ---------------------------------------------------------------------------

struct Board
    O::V3      # board-frame origin in world coords (internal corner (0,0))
    e1::V3
    e2::V3
    checker::Float64
    n::Tuple{Int, Int}
end

# Pattern spans one checker beyond the internal corners; a white quiet zone of one checker beyond
# that, which findChessboardCorners needs to see the board at all.
function board_color(b::Board, u, v)
    lo1, hi1 = -b.checker, b.n[1] * b.checker
    lo2, hi2 = -b.checker, b.n[2] * b.checker
    q = b.checker
    (lo1 - q <= u <= hi1 + q && lo2 - q <= v <= hi2 + q) || return nothing
    (lo1 <= u <= hi1 && lo2 <= v <= hi2) || return 0.95        # quiet zone
    i = floor(Int, u / b.checker)
    j = floor(Int, v / b.checker)
    return iseven(i + j) ? 0.95 : 0.05
end

board_point(b::Board, u, v) = b.O + u * b.e1 + v * b.e2

function floor_color(t, dots, X, Y)
    for d in dots
        hypot(X - d[1], Y - d[2]) <= t.dot_r && return 0.08     # a dot
    end
    hypot(X, Y) > t.arena_r && return 0.25                      # surround
    return 0.72                                                  # arena floor
end

# Render one frame: stored h×w gray, 4x4 explicit supersampling per stored pixel (#280: area
# integration is supersampling, never an interpolation flag).
function render(t, R, C, board, dots; ss = 4)
    rmax = fold_radius(t.k)
    img = Matrix{Float64}(undef, t.h, t.w)
    Rt = R'
    sarf = float(t.sar)
    Threads.@threads for i in 1:t.h
        for j in 1:t.w
            acc = 0.0
            for a in 0:(ss - 1), b in 0:(ss - 1)
                rowc = (i - 1) - 0.5 + (a + 0.5) / ss           # 0-based stored coords
                colc = (j - 1) - 0.5 + (b + 0.5) / ss
                xd = (colc * sarf - t.cx) / t.f                 # distorted normalised
                yd = (rowc - t.cy) / t.f
                rd = hypot(xd, yd)
                ru = undistort_radius(rd, t.k, rmax)
                if isnan(ru)
                    acc += 0.0
                    continue
                end
                s = rd == 0 ? 1.0 : ru / rd
                dir = Rt * V3(xd * s, yd * s, 1)
                val = 0.0
                tb = Inf
                if board !== nothing
                    nb = cross(board.e1, board.e2)
                    den = dir ⋅ nb
                    if abs(den) > 1.0e-12
                        tt = ((board.O - C) ⋅ nb) / den
                        if tt > 0
                            P = C + tt * dir
                            d = P - board.O
                            col = board_color(board, d ⋅ board.e1, d ⋅ board.e2)
                            if col !== nothing
                                tb = tt
                                val = col
                            end
                        end
                    end
                end
                if tb == Inf
                    if dir[3] < -1.0e-12
                        tf = -C[3] / dir[3]
                        P = C + tf * dir
                        val = floor_color(t, dots, P[1], P[2])
                    else
                        val = 0.0                                # sky
                    end
                end
                acc += val
            end
            img[i, j] = acc / ss^2
        end
    end
    return img
end

# ---------------------------------------------------------------------------
# Encoding and reading back, the way Fromage does it.
# ---------------------------------------------------------------------------

function encode(path, frames, t)
    sar = "$(numerator(t.sar))/$(denominator(t.sar))"
    cmd = `$(FFMPEG.ffmpeg()) -y -hide_banner -loglevel error -f rawvideo -pix_fmt gray
        -s $(t.w)x$(t.h) -r 1 -i pipe:0 -c:v libx264 -qp 0 -g 1 -preset veryfast
        -vf setsar=$sar -pix_fmt yuv420p $path`
    open(cmd, "w") do io
        for img in frames
            # rawvideo is row-major; a Julia matrix written as-is goes column-major, which
            # encodes a transposed frame. `permutedims` is not optional here.
            write(io, UInt8.(round.(clamp.(permutedims(img), 0, 1) .* 255)))
        end
    end
    return path
end

function read_frame(path, t, secs)
    buf = read(`$(FFMPEG.ffmpeg()) -hide_banner -loglevel error -ss $secs -i $path -frames:v 1 -f rawvideo -pix_fmt gray pipe:1`)
    return permutedims(reshape(buf, t.w, t.h))
end

# ---------------------------------------------------------------------------
# Independent dot detection: threshold, flood fill, intensity-weighted centroid.
# Returns 0-based stored (row, col) — the same origin OpenCV's corners use (#277's advice).
# ---------------------------------------------------------------------------

function detect_dots(img)
    v = Float64.(vec(img))
    hi = maximum(v)
    # The background is the ARENA FLOOR, not the frame: on a portrait frame the arena can be a
    # minority of the image and a global median lands on the sky, collapsing the threshold to zero.
    # Take the most common value among the bright half instead.
    counts = Dict{Int, Int}()
    for x in v
        x >= 0.5hi || continue
        k = round(Int, x)
        counts[k] = get(counts, k, 0) + 1
    end
    isempty(counts) && return SVector{2, Float64}[]
    bg = Float64(argmax(counts))
    thr = 0.6bg
    mask = img .< thr
    h, w = size(img)
    seen = falses(h, w)
    blobs = Vector{Tuple{Float64, Float64, Float64}}()
    for i in 1:h, j in 1:w
        (mask[i, j] && !seen[i, j]) || continue
        stack = [(i, j)]
        seen[i, j] = true
        wsum = 0.0
        rsum = 0.0
        csum = 0.0
        area = 0
        touches_border = false
        while !isempty(stack)
            (a, b) = pop!(stack)
            area += 1
            (a == 1 || b == 1 || a == h || b == w) && (touches_border = true)
            wgt = max(0.0, bg - Float64(img[a, b]))
            wsum += wgt
            rsum += wgt * (a - 1)          # 0-based stored coordinates, OpenCV's origin
            csum += wgt * (b - 1)
            for (da, db) in ((1, 0), (-1, 0), (0, 1), (0, -1))
                p, q = a + da, b + db
                (1 <= p <= h && 1 <= q <= w) || continue
                (mask[p, q] && !seen[p, q]) || continue
                seen[p, q] = true
                push!(stack, (p, q))
            end
        end
        # a dot is small, does not touch the frame edge, and is more than a stray pixel
        (touches_border || area > 0.01 * h * w || area < 5) && continue
        wsum > 0 && push!(blobs, (wsum, rsum / wsum, csum / wsum))
    end
    sort!(blobs, by = first, rev = true)
    return [SVector(b[2], b[3]) for b in blobs[1:min(2, end)]]
end

# ---------------------------------------------------------------------------
# One trial, end to end.
# ---------------------------------------------------------------------------

# Rejection-sample a board pose whose internal corners and quiet zone all project inside the frame.
function sample_board(t, R, C; flat, tries = 600)
    rmax = fold_radius(t.k)
    # the board's full extent, quiet zone included
    ext1 = (t.n_corners[1] + 3) * t.checker
    ext2 = (t.n_corners[2] + 3) * t.checker
    diag = hypot(ext1, ext2)
    for _ in 1:tries
        θ = 2π * rand(t.rng)
        if flat
            # lying on the arena: the only freedom is where and which way round
            O = V3(
                t.aim[1] + 0.2t.arena_r * (rand(t.rng) - 0.5) - 0.5t.checker * t.n_corners[1],
                t.aim[2] + 0.2t.arena_r * (rand(t.rng) - 0.5) - 0.5t.checker * t.n_corners[2], 0
            )
            e1 = V3(cos(θ), sin(θ), 0)
            e2 = V3(-sin(θ), cos(θ), 0)
            b = Board(O, e1, e2, t.checker, t.n_corners)
        else
            # waved: CONSTRUCT the distance from the span we want, rather than rejecting until a
            # random distance happens to work. A 15 cm board only fills a frame near the lens.
            want = 0.30 + 0.40 * rand(t.rng)
            dist = t.f * diag / (want * min(t.w, t.h))
            # aim it through a pixel in the middle half of the frame
            rowc = t.h * (0.25 + 0.5rand(t.rng))
            colc = t.w * (0.25 + 0.5rand(t.rng))
            ray = pixel_ray(t, R, C, rowc, colc, rmax)
            ray === nothing && continue
            centre = C + dist * ray
            # normal within 35° of facing the camera, so the board is legible but not fronto-parallel
            tiltb = deg2rad(35 * rand(t.rng))
            φ = 2π * rand(t.rng)
            ref = abs(ray[3]) > 0.99 ? V3(0, 1, 0) : V3(0, 0, 1)
            a1 = normalize(cross(ref, ray))
            a2 = cross(ray, a1)
            nrm = normalize(-cos(tiltb) * ray + sin(tiltb) * (cos(φ) * a1 + sin(φ) * a2))
            e1 = normalize(cross(nrm, cos(θ) * a1 + sin(θ) * a2))
            e2 = cross(nrm, e1)
            O = centre - 0.5 * ((t.n_corners[1] - 1) * t.checker * e1 + (t.n_corners[2] - 1) * t.checker * e2)
            b = Board(O, e1, e2, t.checker, t.n_corners)
            # must stay above the arena floor
            all(
                board_point(b, i * t.checker, j * t.checker)[3] > 5
                    for i in (-2, t.n_corners[1] + 1), j in (-2, t.n_corners[2] + 1)
            ) || continue
        end
        ok = true
        m = 0.04 * min(t.w, t.h)
        ps = SVector{2, Float64}[]
        for i in (-2, t.n_corners[1] + 1), j in (-2, t.n_corners[2] + 1)
            p = project(t, R, C, board_point(b, i * t.checker, j * t.checker))
            if p === nothing || !(m <= p[1] <= t.h - 1 - m) || !(m <= p[2] <= t.w - 1 - m)
                ok = false
                break
            end
            push!(ps, p)
        end
        if ok
            span = max(
                maximum(p[1] for p in ps) - minimum(p[1] for p in ps),
                maximum(p[2] for p in ps) - minimum(p[2] for p in ps)
            )
            # how much of the frame a pose must cover — exactly what #284 has to pin down
            minflat = parse(Float64, get(ENV, "PROTO_MIN_FLAT", "0.08"))
            ok = span >= (flat ? minflat : 0.25) * min(t.w, t.h)
        end
        ok && return b
    end
    return nothing
end

function run_trial(seed; sar_override = nothing, nwave = 8, verbose = true)
    t = draw_trial(seed; sar_override)
    R, C = camera_pose(t)
    dir = mktempdir()

    # dots, placed on the arena floor, allowed outside the flat board's footprint
    ϕ = 2π * rand(t.rng)
    mid = t.aim + 0.3t.arena_r * SVector(cos(2π * rand(t.rng)), sin(2π * rand(t.rng)))
    dirv = SVector(cos(ϕ), sin(ϕ))
    halfmax = t.arena_r - t.dot_r - norm(mid)
    half = min(t.sep / 2, max(halfmax, 5.0))
    d1 = mid + half * dirv
    d2 = mid - half * dirv
    true_sep = norm(d1 - d2)

    grow = 1.0
    flat = nothing
    for g in (1.0, 1.5, 2.25, 3.375)
        t = merge(t, (; checker = draw_trial(seed; sar_override).checker * g))
        flat = sample_board(t, R, C; flat = true)
        if flat !== nothing
            grow = g
            break
        end
    end
    flat === nothing && return (; t, failed = "no flat board pose fits in frame even at 3.4x board size")
    flat_span = let ps = [project(t, R, C, board_point(flat, i * t.checker, j * t.checker))
            for i in (-2, t.n_corners[1] + 1), j in (-2, t.n_corners[2] + 1)]
        max(maximum(p[1] for p in ps) - minimum(p[1] for p in ps),
            maximum(p[2] for p in ps) - minimum(p[2] for p in ps))
    end
    waved = Board[]
    for _ in 1:nwave
        b = sample_board(t, R, C; flat = false)
        b === nothing || push!(waved, b)
    end
    length(waved) < 3 && return (; t, failed = "only $(length(waved)) waved poses fit in frame")

    verbose && @printf(
        "  rendering %d calibration frames at %d×%d (sar %s)…\n",
        length(waved) + 1, t.w, t.h, string(t.sar)
    )
    calib = [render(t, R, C, b, ()) for b in waved]
    push!(calib, render(t, R, C, flat, ()))
    target = render(t, R, C, nothing, (d1, d2))

    if get(ENV, "PROTO_DUMP", "0") == "1"
        for (nm, im) in (("extrinsic", calib[end]), ("waved1", calib[1]), ("target", target))
            pgm = joinpath(@__DIR__, "dump_$(seed)_$(nm).pgm")
            open(pgm, "w") do io
                write(io, "P5\n$(t.w) $(t.h)\n255\n")
                write(io, UInt8.(round.(clamp.(permutedims(im)[:], 0, 1) .* 255)))
            end
            run(`$(FFMPEG.ffmpeg()) -y -hide_banner -loglevel error -i $pgm $(splitext(pgm)[1] * ".png")`)
            rm(pgm)
        end
    end

    board_file = encode(joinpath(dir, "board.mp4"), calib, t)
    target_file = encode(joinpath(dir, "target.mp4"), [target, target, target], t)

    aspect = float(t.sar)
    common = (;
        file = board_file, extrinsic = float(length(waved)), yadif = missing, blur = 0,
        width = t.w, height = t.h, n_corners = t.n_corners, checker_width = t.checker,
        aspect, center = missing, north = missing,
    )
    rect_cb = try
        from_checkerboard(; common..., intrinsic_start = 0.0,
            intrinsic_stop = float(length(waved) - 1), temporal_step = 1.0, radial_parameters = 3)
    catch e
        e
    end
    rect_ex = try
        from_extrinsic(; common...)
    catch e
        e
    end

    per_t = [
        (tt, get_corners(board_file, float(tt), missing, t.w, t.h, t.n_corners) !== missing)
            for tt in 0:length(waved)
    ]

    # is a failed detection the flag, or the board? probe the same frame without FAST_CHECK
    probe = let
        OpenCV = Fromage.Rectifications.OpenCV
        img0 = read_frame(board_file, t, length(waved))
        m = OpenCV.Mat(reshape(img0, 1, t.h, t.w))
        out = Matrix{SVector{2, Float32}}(undef, t.n_corners)
        res = Dict{String, Bool}()
        for (nm, fl) in (
                "Fromage's flags" => OpenCV.CALIB_CB_ADAPTIVE_THRESH + OpenCV.CALIB_CB_NORMALIZE_IMAGE + OpenCV.CALIB_CB_FAST_CHECK,
                "without FAST_CHECK" => OpenCV.CALIB_CB_ADAPTIVE_THRESH + OpenCV.CALIB_CB_NORMALIZE_IMAGE,
                "transposed n_corners" => OpenCV.CALIB_CB_ADAPTIVE_THRESH + OpenCV.CALIB_CB_NORMALIZE_IMAGE,
            )
            nc = nm == "transposed n_corners" ? reverse(t.n_corners) : t.n_corners
            o = Matrix{SVector{2, Float32}}(undef, nc)
            ret, _ = OpenCV.findChessboardCorners(
                m, OpenCV.Size{Int32}(nc...),
                OpenCV.Mat(reshape(reinterpret(Float32, o), 2, 1, prod(nc))), fl
            )
            res[nm] = ret
        end
        res
    end

    # renderer accuracy: Fromage's own corner detection against the true projections
    corner_rms = let
        det = get_corners(board_file, float(length(waved)), missing, t.w, t.h, t.n_corners)
        if det === missing
            NaN
        else
            truth = [project(t, R, C, board_point(flat, i * t.checker, j * t.checker))
                for i in 0:(t.n_corners[1] - 1), j in 0:(t.n_corners[2] - 1)]
            best = Inf
            for fl in (identity, reverse, x -> reverse(x, dims = 1), x -> reverse(x, dims = 2))
                d = try
                    fl(truth)
                catch
                    continue
                end
                size(d) == size(det) || continue
                r = sqrt(mean(sum(abs2, SVector{2, Float64}(det[i]...) .- d[i]) for i in eachindex(d)))
                best = min(best, r)
            end
            best
        end
    end

    img = read_frame(target_file, t, 1)
    dots = detect_dots(img)
    truth_px = [project(t, R, C, V3(d[1], d[2], 0)) for d in (d1, d2)]
    det_err = if length(dots) == 2
        p = sort(dots, by = x -> x[1] + x[2])
        q = sort(truth_px, by = x -> x[1] + x[2])
        maximum(norm(p[i] - q[i]) for i in 1:2)
    else
        NaN
    end

    measure(rect, pts) = (rect isa Exception || length(pts) < 2) ? NaN :
        norm(rect.image2real(SVector(pts[1]...)) - rect.image2real(SVector(pts[2]...)))

    out = (;
        t, failed = nothing, true_sep, corner_rms, det_err, probe, per_t, flat_span, grow, nwaved = length(waved), ndots = length(dots),
        cb = measure(rect_cb, dots), ex = measure(rect_ex, dots),
        cb_plus1 = measure(rect_cb, [d .+ 1 for d in dots]),     # the #276 tracker convention
        err_cb = rect_cb isa Exception ? rect_cb : nothing,
        err_ex = rect_ex isa Exception ? rect_ex : nothing,
    )
    return out
end

function report(r)
    t = r.t
    @printf("\n── seed %d ", t.seed)
    println("─"^54)
    @printf(
        "  %d×%d stored, sar %s, fov %.0f°, f %.0f px, k1 %.3f\n",
        t.w, t.h, string(t.sar), rad2deg(t.fov), t.f, t.k[1]
    )
    @printf(
        "  camera %.0f cm up, %.0f° off nadir | arena ⌀%.0f cm | board %s at %.1f cm | dots ⌀%.1f cm\n",
        t.height, rad2deg(t.tilt), 2t.arena_r, string(t.n_corners), t.checker, 2t.dot_r
    )
    if r.failed !== nothing
        println("  FAILED: ", r.failed)
        return
    end
    @printf("  flat board spans %.0f px (%.0f%% of the short side), checker %.1f cm (grown %.2fx); %d waved poses\n",
        r.flat_span, 100r.flat_span / min(t.w, t.h), t.checker, r.grow, r.nwaved)
    println("  corners per encoded second: ", join([(x[2] ? "$(x[1])✓" : "$(x[1])✗") for x in r.per_t], " "))
    println("  detection probe: ", join(["$k=$(v ? "found" : "MISSED")" for (k, v) in r.probe], ", "))
    @printf("  corner RMS vs true projection: %.3f stored px\n", r.corner_rms)
    @printf("  dots found: %d | detection error: %.3f stored px\n", r.ndots, r.det_err)
    @printf("  true separation:      %.4f cm\n", r.true_sep)
    for (name, val) in (("from_checkerboard", r.cb), ("from_extrinsic", r.ex), ("from_checkerboard, +1 px (the #276 convention)", r.cb_plus1))
        if isnan(val)
            @printf("  %-46s FAILED\n", name)
        else
            @printf("  %-46s %.4f cm   (%+.4f cm, %+.3f %%)\n", name, val, val - r.true_sep, 100(val - r.true_sep) / r.true_sep)
        end
    end
    r.err_cb === nothing || println("  from_checkerboard threw: ", r.err_cb)
    r.err_ex === nothing || println("  from_extrinsic threw: ", r.err_ex)
    return
end

if get(ENV, "PROTO_LIB", "0") == "1"   # included as a library by a debug script
    return
end

seeds = isempty(ARGS) ? [1] : parse.(Int, ARGS)
println("threads: ", Threads.nthreads())
for s in seeds
    r = run_trial(s)
    report(r)
    if r.failed === nothing
        rc = run_trial(s; sar_override = 1 // 1)
        if rc.failed === nothing
            @printf("  control at sar = 1: checkerboard %+.4f cm | extrinsic %+.4f cm | +1 px %+.4f cm (true %.4f)\n",
                rc.cb - rc.true_sep, rc.ex - rc.true_sep, rc.cb_plus1 - rc.true_sep, rc.true_sep)
        else
            println("  control at sar = 1 FAILED: ", rc.failed)
        end
    end
end
