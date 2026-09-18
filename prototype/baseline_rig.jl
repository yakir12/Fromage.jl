# PROTOTYPE — THROWAWAY. Answers Fromage.jl issue #291 (wayfinder map #289): does the baseline rig
# work end to end through the builders, and what does it measure?
#
# Renders the baseline rig the map specifies (arena, dots, floor and board as objects; camera at
# (1.5, 0, 1.5) m aimed at the origin; ideal sensor, 4×4 supersampling, 8 bit), encodes it losslessly,
# calls `from_checkerboard` and `from_extrinsic`, and prints every check against analytic truth.
#
# Not production code: one file, no tests, prints everything. Starts from #283's renderer.
# Run:  JULIA_NUM_THREADS=auto julia --project=test prototype/baseline_rig.jl
# Knobs (env): RIG_F, RIG_CX, RIG_CY (display px, 0-based), RIG_K1, RIG_SAR (e.g. 4/3),
#              RIG_SS (supersampling), RIG_OUT (folder for PNGs and the videos).

using LinearAlgebra: norm, cross, normalize, dot, svd, det, Diagonal
using Statistics: mean
using Printf: @printf, @sprintf
using StaticArrays: SVector, SMatrix
using FFMPEG: FFMPEG
using Fromage: Fromage

const RX = Fromage.Rectifications
const V3 = SVector{3, Float64}
const V2 = SVector{2, Float64}

envf(k, d) = parse(Float64, get(ENV, k, string(d)))
envr(k, d) = (s = split(get(ENV, k, d), '/'); parse(Int, s[1]) // parse(Int, get(s, 2, "1")))

# ---------------------------------------------------------------------------------------------------
# The rig. Units: metres in the world, pixels in the image. Display pixels are square; stored
# column = display x / sar (Fromage's `to_stored`). 0-based, pixel centres on integers (OpenCV's).
# ---------------------------------------------------------------------------------------------------

const SAR = envr("RIG_SAR", "1")
const W = SAR >= 1 ? round(Int, 1920 / SAR) : 1920             # stored width
const H = SAR >= 1 ? 1080 : round(Int, 1080 * SAR)             # stored height
# the optics are fixed in the DISPLAY frame; for sar < 1 the display frame is H/sar tall in square px
# … but Fromage displays sar < 1 at stored height and width·sar (#293), so express optics in that
# frame: display = (col·sar, row). For sar ≥ 1 that is the 1920×1080 frame.
const DW, DH = W * float(SAR), float(H)
const DSCALE = SAR >= 1 ? 1.0 : float(SAR)                      # display frame is scaled for sar < 1
const F = envf("RIG_F", 900.0) * DSCALE
const CX = envf("RIG_CX", 959.5 + 12.3) * DSCALE
const CY = envf("RIG_CY", 539.5 - 7.8) * DSCALE
const K = (envf("RIG_K1", 0.0), 0.0, 0.0)
const SS = parse(Int, get(ENV, "RIG_SS", "4"))
const CAM = V3(1.5, 0.0, 1.5)

# camera frame: x right, y down, z forward (a right-handed OpenCV frame)
const FWD = normalize(-CAM)
const DOWN = normalize(V3(0, 0, -1) - dot(V3(0, 0, -1), FWD) * FWD)
const RIGHT = cross(DOWN, FWD)
const ROT = SMatrix{3, 3}(RIGHT[1], DOWN[1], FWD[1], RIGHT[2], DOWN[2], FWD[2], RIGHT[3], DOWN[3], FWD[3])

distortion(r2) = 1 + K[1] * r2 + K[2] * r2^2 + K[3] * r2^3

# world point → stored (row, col), or `nothing` behind the camera
function project(P::V3)
    p = ROT * (P - CAM)
    p[3] <= 1.0e-9 && return nothing
    x, y = p[1] / p[3], p[2] / p[3]
    g = distortion(x^2 + y^2)
    return V2(CY + F * y * g, (CX + F * x * g) / SAR)
end

# the explicit fold guard: first stationary point of r·f(r), found by scanning (Inf when monotone)
const FOLD = let r = 0.0, out = Inf
    while r < 8
        1 + 3K[1] * r^2 + 5K[2] * r^4 + 7K[3] * r^6 <= 0 && (out = r; break)
        r += 1.0e-4
    end
    out
end

# bracketed inverse of the radial model; NaN past the fold
function undistort(rd)
    rd == 0 && return 0.0
    all(iszero, K) && return rd
    hi = isfinite(FOLD) ? FOLD : 8.0
    rd > hi * distortion(hi^2) && return NaN
    lo = 0.0
    for _ in 1:80
        m = (lo + hi) / 2
        m * distortion(m^2) < rd ? (lo = m) : (hi = m)
    end
    return (lo + hi) / 2
end

# the world ray through stored (row, col)
function ray(row, col)
    xd, yd = (col * SAR - CX) / F, (row - CY) / F
    rd = hypot(xd, yd)
    ru = undistort(rd)
    isnan(ru) && return nothing
    s = rd == 0 ? 1.0 : ru / rd
    return ROT' * V3(xd * s, yd * s, 1)
end

# ---------------------------------------------------------------------------------------------------
# The objects. Precedence is explicit: board > dots > arena > floor (#283 lost a dot to draw order).
# ---------------------------------------------------------------------------------------------------

const SQ = 0.04                     # checker square
const HALF = (0.22, 0.16)           # 11×8 squares, centred
const MARGIN = SQ                   # one-square white margin → 52×40 cm
const NINNER = (10, 7)              # inner corners along e1 (long), e2 (short)
const DOTS = (V2(0, 0.5), V2(0, -0.5))
const DOT_R = 0.02

# `O` the board's centre, `e1` its long axis, `e2` its short axis; the printed face's outward normal
# is e2 × e1, so a board seen from the front shows e1 → right, e2 → down, whatever its pose.
struct Board
    O::V3
    e1::V3
    e2::V3
end

function board_reflectance(u, v)
    (abs(u) > HALF[1] + MARGIN || abs(v) > HALF[2] + MARGIN) && return nothing
    (abs(u) > HALF[1] || abs(v) > HALF[2]) && return 1.0
    return iseven(floor(Int, (u + HALF[1]) / SQ) + floor(Int, (v + HALF[2]) / SQ)) ? 0.0 : 1.0
end

inner_corners(b::Board) = [b.O + (-HALF[1] + SQ * i) * b.e1 + (-HALF[2] + SQ * j) * b.e2 for i in 1:NINNER[1], j in 1:NINNER[2]]
outline(b::Board) = [
    b.O + u * b.e1 + v * b.e2 for (u, v) in Iterators.flatten(
            (
                ((t * (HALF[1] + MARGIN), s * (HALF[2] + MARGIN)) for t in range(-1, 1, 21), s in (-1, 1)),
                ((s * (HALF[1] + MARGIN), t * (HALF[2] + MARGIN)) for t in range(-1, 1, 21), s in (-1, 1)),
            )
        )
]

function ground(X, Y)
    any(d -> hypot(X - d[1], Y - d[2]) <= DOT_R, DOTS) && return 0.0      # dots, painted on the arena
    hypot(X, Y) <= 1.0 && return 1.0                                       # arena
    return 0.5                                                             # floor
end

const SKY = Threads.Atomic{Int}(0)

function cast(d::V3, board)
    tg = d[3] < 0 ? -CAM[3] / d[3] : Inf
    if board !== nothing
        n = cross(board.e1, board.e2)
        den = dot(d, n)
        if abs(den) > 1.0e-12
            tb = dot(board.O - CAM, n) / den
            if 0 < tb <= tg + 1.0e-9          # coplanar flat board: the board is painted on top
                q = CAM + tb * d - board.O
                ρ = board_reflectance(dot(q, board.e1), dot(q, board.e2))
                ρ === nothing || return ρ
            end
        end
    end
    isfinite(tg) || (Threads.atomic_add!(SKY, 1); return 0.0)
    P = CAM + tg * d
    return ground(P[1], P[2])
end

# the ideal sensor: mean reflectance over each stored pixel's footprint, SS×SS explicit samples
function render(board)
    img = Matrix{UInt8}(undef, H, W)
    Threads.@threads for i in 1:H
        for j in 1:W
            acc = 0.0
            for a in 0:(SS - 1), b in 0:(SS - 1)
                d = ray((i - 1) - 0.5 + (a + 0.5) / SS, (j - 1) - 0.5 + (b + 0.5) / SS)
                acc += d === nothing ? 0.0 : cast(d, board)
            end
            img[i, j] = round(UInt8, 255 * acc / SS^2)
        end
    end
    return img
end

# ---------------------------------------------------------------------------------------------------
# Board poses.
# ---------------------------------------------------------------------------------------------------

rotate(v, a, θ) = v * cos(θ) + cross(a, v) * sin(θ) + a * dot(a, v) * (1 - cos(θ))

const EDGE = round(Int, 0.03 * min(DW, DH))                    # keep the whole board this far inside

function inframe(b::Board; m = EDGE)
    for P in outline(b)
        p = project(P)
        (p === nothing || !(m <= p[1] <= H - 1 - m) || !(m <= p[2] * SAR <= DW - 1 - m)) && return false
    end
    return true
end

# largest scalar in (lo, hi) keeping `make(s)` in frame, assuming monotone
function fit(make, lo, hi; want_small = false)
    for _ in 1:50
        m = (lo + hi) / 2
        if inframe(make(m)) == want_small
            hi = m
        else
            lo = m
        end
    end
    return want_small ? hi : lo
end

# waved: facing the camera on the optical axis, rotated about one in-plane axis, as close as fits
function waved(axis, deg)
    e1, e2 = RIGHT, DOWN
    a = axis == :e2 ? e2 : e1
    e1, e2 = rotate(e1, a, deg2rad(deg)), rotate(e2, a, deg2rad(deg))
    make(D) = Board(CAM + D * FWD, e1, e2)
    D = fit(make, 0.1, 5.0; want_small = true)                  # smallest distance that fits
    return make(D), D
end

# corner poses: ~⅓ of the frame, facing the camera, tilted 30°, pushed as far into a corner as fits
const CORNER_FRAC = envf("RIG_CORNER_FRAC", 1 / 3)             # the untilted board's share of the width
const CORNER_TILT = envf("RIG_CORNER_TILT", 30)

function corner(sx, sy; tilt = CORNER_TILT)
    D = F * 2(HALF[1] + MARGIN) / (DW * CORNER_FRAC)
    function make(s)
        r = normalize(ray(CY + s * sy * DH / 2, (CX + s * sx * DW / 2) / SAR))
        e1 = normalize(RIGHT - dot(RIGHT, r) * r)
        e2 = cross(r, e1)
        radial = normalize(sx * e1 + sy * e2)
        τ = cross(r, radial)                                    # in-plane, perpendicular to radial
        return Board(CAM + D * r, rotate(e1, τ, deg2rad(tilt)), rotate(e2, τ, deg2rad(tilt)))
    end
    s = fit(make, 0.0, 1.0)
    return make(s), s, D
end

const FLAT = Board(V3(0, 0, 0), V3(0, 1, 0), V3(1, 0, 0))     # long axis along y, face up

span(b) = let ps = [project(P) for P in outline(b)]
    ((maximum(p[2] for p in ps) - minimum(p[2] for p in ps)) * SAR / DW, (maximum(p[1] for p in ps) - minimum(p[1] for p in ps)) / DH)
end

# ---------------------------------------------------------------------------------------------------
# Encoding, lossless (#293's recipe), and the simulation's own dot detector.
# ---------------------------------------------------------------------------------------------------

function encode(path, frames)
    sar = "$(numerator(SAR))/$(denominator(SAR))"
    cmd = `$(FFMPEG.ffmpeg()) -y -hide_banner -loglevel error -f rawvideo -pix_fmt gray -s $(W)x$H -r 1
        -i pipe:0 -vf setsar=$sar -c:v libx264 -qp 0 -pix_fmt gray $path`
    open(cmd, "w") do io
        for img in frames
            write(io, permutedims(img))                         # raw video is row-major
        end
    end
    return path
end

png(path, img) = open(
    `$(FFMPEG.ffmpeg()) -y -hide_banner -loglevel error -f rawvideo -pix_fmt gray -s $(W)x$H -i pipe:0 $path`, "w"
) do io
    write(io, permutedims(img))
end

# dark blobs → area-weighted centroid over a padded box. The background is the ARENA (255 here:
# #283's lesson), so a pixel outside the dot weighs exactly zero; partial pixels weigh their share.
function detect_dots(img)
    dark = img .< 128
    seen = falses(size(img))
    out = V2[]
    for i in axes(img, 1), j in axes(img, 2)
        (dark[i, j] && !seen[i, j]) || continue
        stack, px = [(i, j)], Tuple{Int, Int}[]
        seen[i, j] = true
        while !isempty(stack)
            a, b = pop!(stack)
            push!(px, (a, b))
            for (p, q) in ((a + 1, b), (a - 1, b), (a, b + 1), (a, b - 1))
                checkbounds(Bool, img, p, q) && dark[p, q] && !seen[p, q] && (seen[p, q] = true; push!(stack, (p, q)))
            end
        end
        (5 <= length(px) <= 5000) || continue
        r1, r2 = extrema(first, px)
        c1, c2 = extrema(last, px)
        ws = rs = cs = 0.0
        for a in max(1, r1 - 3):min(H, r2 + 3), b in max(1, c1 - 3):min(W, c2 + 3)
            w = 255.0 - img[a, b]
            ws += w
            rs += w * (a - 1)
            cs += w * (b - 1)
        end
        push!(out, V2(rs / ws, cs / ws))
    end
    return out
end

# ---------------------------------------------------------------------------------------------------
# Measuring.
# ---------------------------------------------------------------------------------------------------

stats(v) = isempty(v) ? (NaN, NaN) : (sqrt(mean(abs2, v)), maximum(abs, v))

# rigid 2D Procrustes (rotation + translation, no scale): residual after the best alignment
function procrustes(A, B)
    ma, mb = mean(A), mean(B)
    M = sum((a - ma) * (b - mb)' for (a, b) in zip(A, B))
    U, _, V = svd(M)
    Rm = V * Diagonal([1, sign(det(V * U'))]) * U'
    return [norm(Rm * (a - ma) + mb - b) for (a, b) in zip(A, B)]
end

display_xy(p) = (p[2] * SAR, p[1])                             # stored (row, col) → display (x, y)

function map_errors(rect, pts)
    got = [V2(rect.image2real(project(V3(P[1], P[2], 0)))) for P in pts]
    truth = [V2(-100P[2], 100P[1]) for P in pts]                # #290: real (y, x) = (−Y, X), cm
    return [10norm(g - t) for (g, t) in zip(got, truth)], 10procrustes(got, truth)
end

nodeflags() = RX.OpenCV.CALIB_CB_ADAPTIVE_THRESH + RX.OpenCV.CALIB_CB_NORMALIZE_IMAGE
function detect_nofast(img)
    OpenCV = RX.OpenCV
    c = Matrix{SVector{2, Float32}}(undef, (7, 10))
    ret, _ = OpenCV.findChessboardCorners(
        OpenCV.Mat(reshape(img, 1, H, W)), OpenCV.Size{Int32}(7, 10),
        OpenCV.Mat(reshape(reinterpret(Float32, c), 2, 1, 70)), nodeflags()
    )
    return ret ? c : missing
end

# each detected corner against its nearest analytic projection (errors ≪ the corner spacing)
function corner_errors(det, b)
    truth = [project(P) for P in inner_corners(b)]
    matched = [truth[argmin([norm(V2(d) - t) for t in truth])] for d in det]
    return [norm(V2(d) - m) for (d, m) in zip(det, matched)], matched
end

function main()
    out = get(ENV, "RIG_OUT", mktempdir())
    mkpath(out)
    @printf("threads %d | stored %d×%d, sar %s | f %.2f, c (%.2f, %.2f) display px | k %s | %d×%d supersampling\n",
        Threads.nthreads(), W, H, string(SAR), F, CX, CY, string(K), SS, SS)

    # ---- where the arena and the dots land
    rim = [project(V3(cos(θ), sin(θ), 0)) for θ in range(0, 2π, 721)]
    @printf("arena in frame: rows %.1f–%.1f of %d, display x %.1f–%.1f of %.0f → margins top %.0f, bottom %.0f, left %.0f, right %.0f px\n",
        minimum(first, rim), maximum(first, rim), H, minimum(p -> p[2] * SAR, rim), maximum(p -> p[2] * SAR, rim), DW,
        minimum(first, rim), H - 1 - maximum(first, rim), minimum(p -> p[2] * SAR, rim), DW - 1 - maximum(p -> p[2] * SAR, rim))
    dotpx = [project(V3(d[1], d[2], 0)) for d in DOTS]
    @printf("dots at stored (row, col) %s and %s; a dot is ~%.1f px across\n",
        string(round.(dotpx[1], digits = 2)), string(round.(dotpx[2], digits = 2)),
        norm(project(V3(DOTS[1][1], DOTS[1][2] + DOT_R, 0)) - project(V3(DOTS[1][1], DOTS[1][2] - DOT_R, 0))))
    vfov = rad2deg(atan((H - 1 - CY) / F) + atan(CY / F))
    @printf("vertical field of view %.1f°, horizontal %.1f°\n", vfov, rad2deg(atan((DW - 1 - CX) / F) + atan(CX / F)))

    # ---- the poses
    poses = Tuple{String, Board}[]
    for deg in -70:10:70
        b, D = waved(:e2, deg)
        push!(poses, (@sprintf("about e2 %+3d° (D %.2f m)", deg, D), b))
    end
    for deg in -70:10:70
        deg == 0 && continue
        b, D = waved(:e1, deg)
        push!(poses, (@sprintf("about e1 %+3d° (D %.2f m)", deg, D), b))
    end
    for (sx, sy) in ((-1, -1), (1, -1), (-1, 1), (1, 1))
        b, s, D = corner(sx, sy)
        push!(poses, (@sprintf("corner %s%s (D %.2f m, pushed %.0f%%)", sy < 0 ? "top" : "bottom", sx < 0 ? "left" : "right", D, 100s), b))
    end
    push!(poses, ("flat, extrinsic", FLAT))
    println("\nposes: ", length(poses) - 1, " waved + the flat board")

    t0 = time()
    frames = [render(b) for (_, b) in poses]
    target = render(nothing)
    @printf("rendered %d frames in %.1f s; rays that missed the ground (sky): %d\n", length(frames) + 1, time() - t0, SKY[])

    file = encode(joinpath(out, "board.mp4"), frames)
    tfile = encode(joinpath(out, "target.mp4"), [target])
    for (k, nm) in ((1, "waved_e2_m70"), (8, "waved_e2_0"), (15, "waved_e2_p70"), (30, "corner_tl"), (34, "flat"))
        png(joinpath(out, "$nm.png"), frames[k])
    end
    png(joinpath(out, "target.png"), target)
    back = [RX._frame_at(file, float(k - 1), missing, W, H) for k in eachindex(frames)]
    @printf("lossless round trip: max |decoded − rendered| = %d grey levels over %d frames\n",
        maximum(maximum(abs.(Int.(a) .- Int.(b))) for (a, b) in zip(back, frames)), length(frames))

    # ---- corners: Fromage's detection (blur 1.0, FAST_CHECK) against analytic projections
    vf = RX._vf(missing, 1.0)
    nc = (7, 10)
    println("\nframe  pose                                   span w×h    Fromage  no-FAST  corner err RMS / max (stored px)")
    dets = Any[]
    allerr = Float64[]
    for (k, (name, b)) in enumerate(poses)
        det = RX.get_corners(file, float(k - 1), vf, W, H, nc)
        nofast = detect_nofast(RX._frame_at(file, float(k - 1), vf, W, H))
        push!(dets, det)
        sw, sh = span(b)
        e = det === missing ? Float64[] : first(corner_errors(det, b))
        append!(allerr, e)
        r, m = stats(e)
        @printf("%4d   %-38s %3.0f%%×%3.0f%%   %-7s  %-7s  %s\n", k - 1, name, 100sw, 100sh,
            det === missing ? "MISSED" : "found", nofast === missing ? "MISSED" : "found",
            det === missing ? "" : @sprintf("%.4f / %.4f", r, m))
    end
    r, m = stats(allerr)
    @printf("all detected corners: RMS %.4f, max %.4f stored px over %d corners\n", r, m, length(allerr))
    # radial coverage: how far out the detected corners reach, as a share of the frame corner's radius
    rad(p) = hypot(p[2] * SAR - CX, p[1] - CY)
    rframe = maximum(rad(V2(a, b / SAR)) for a in (0, H - 1), b in (0, DW - 1))
    for (lbl, ks) in (("waved about an axis", 1:29), ("corner poses", 30:33), ("all", 1:34))
        rs = [rad(V2(c)) for k in ks if dets[k] !== missing for c in dets[k]]
        isempty(rs) || @printf("radial coverage, %-20s max %.0f%% of the frame corner's radius\n", lbl, 100maximum(rs) / rframe)
    end
    # is the corner error the detector's? same frames, no blur
    e0 = Float64[]
    for (k, (_, b)) in enumerate(poses)
        d = RX.get_corners(file, float(k - 1), missing, W, H, nc)
        d === missing || append!(e0, first(corner_errors(d, b)))
    end
    @printf("same frames without blur: RMS %.4f, max %.4f stored px over %d corners\n", stats(e0)..., length(e0))

    # ---- fitted intrinsics, exactly as from_checkerboard fits them (and a control on analytic corners)
    objpoints = RX.XYZ.(Tuple.(CartesianIndices((0:(nc[1] - 1), 0:(nc[2] - 1), 0:0))))
    ok = findall(!ismissing, dets[1:(end - 1)])
    dets[end] === missing && error("the flat board was not detected")
    imgs = [dets[k] for k in ok]
    push!(imgs, dets[end])
    truth_imgs = [RX.RowCol.(last(corner_errors(dets[k], poses[k][2]))) for k in [ok; length(poses)]]
    println("\nintrinsics (stored px)      frow        fcol        crow        ccol        k1")
    @printf("truth                   %10.3f  %10.3f  %10.3f  %10.3f  %10.5f\n", F, F / SAR, CY, CX / SAR, K[1])
    for (lbl, ims) in (("Fromage, detected", imgs), ("control, analytic", truth_imgs))
        mfit = RX.fit_model((H, W), objpoints, ims, nc, 1, float(SAR))
        @printf("%-22s  %10.3f  %10.3f  %10.3f  %10.3f  %10.5f   (k2 %.1g, k3 %.1g)\n", lbl, mfit.frow, mfit.fcol, mfit.crow, mfit.ccol, mfit.k...)
    end

    # ---- the maps, point by point over the arena (5 cm grid), against #290's exact gauge
    center, north = display_xy(project(V3(0, 0, 0))), display_xy(project(V3(0, 0.5, 0)))
    common = (;
        file, extrinsic = float(length(poses) - 1), yadif = missing, blur = 1.0, width = W, height = H,
        n_corners = nc, checker_width = 4.0, aspect = float(SAR), center, north,
    )
    rects = (
        from_checkerboard = RX.from_checkerboard(;
            common..., intrinsic_start = 0.0, intrinsic_stop = float(length(poses) - 2),
            temporal_step = 1.0, radial_parameters = 1
        ),
        from_extrinsic = RX.from_extrinsic(; common...),
    )
    # controls: the same fits on analytic corners, through the builders' shared tail
    shared = (; width = W, height = H, n_corners = nc, checker_width = 4.0, aspect = float(SAR), center, north)
    rects = (;
        rects...,
        control_checkerboard = RX._rectification(; imgpointss = truth_imgs, radial_parameters = 1, shared...),
        control_extrinsic = RX._rectification(; imgpointss = truth_imgs[end:end], radial_parameters = 0, shared...),
    )
    grid = [V2(X, Y) for X in -1:0.05:1, Y in -1:0.05:1 if hypot(X, Y) <= 1]
    onboard(P) = abs(P[2]) <= HALF[1] + MARGIN && abs(P[1]) <= HALF[2] + MARGIN
    println("\nmap vs truth over the arena (mm)      all RMS / max      on board RMS / max   off board RMS / max   Procrustes RMS / max")
    dets_dots = detect_dots(RX._frame_at(tfile, 0.0, missing, W, H))
    for (nm, rect) in pairs(rects)
        e, pr = map_errors(rect, grid)
        on = onboard.(grid)
        @printf("%-36s  %7.3f / %7.3f    %7.3f / %7.3f    %7.3f / %7.3f    %7.3f / %7.3f\n", nm,
            stats(e)..., stats(e[on])..., stats(e[.!on])..., stats(pr)...)
    end

    # ---- the dots
    println("\ndots: found ", length(dets_dots))
    sort!(dets_dots, by = p -> p[2])
    truepx = sort(dotpx, by = p -> p[2])
    for (d, t) in zip(dets_dots, truepx)
        @printf("  centroid %s vs projected centre %s: %.4f stored px\n", string(round.(d, digits = 4)), string(round.(t, digits = 4)), norm(d - t))
    end
    for (nm, rect) in pairs(rects)
        sep(ps) = norm(rect.image2real(ps[1]) - rect.image2real(ps[2]))
        @printf("  %-18s separation, centroids %.4f cm (%+.3f mm) | exact projections %.4f cm (%+.3f mm) | truth 100 cm\n",
            nm, sep(dets_dots), 10(sep(dets_dots) - 100), sep(truepx), 10(sep(truepx) - 100))
    end
    println("\noutput: ", out)
    return
end

get(ENV, "RIG_LIB", "0") == "1" || main()
