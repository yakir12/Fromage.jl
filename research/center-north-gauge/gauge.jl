# Research #290: how center/north place world coordinates in Fromage's real space.
# Baseline rig camera, analytic projection, no rendering (except the OpenCV ordering probe, separate).
using Fromage, LinearAlgebra, Printf
using StaticArrays: SVector, SMatrix, @SMatrix
using Rotations: RotationVec, RotMatrix
const R = Fromage.Rectifications
const Sp = Fromage.Spaces

# ---------------- camera (baseline rig) ----------------
const Cpos = SVector(1.5, 0.0, 1.5)
const fwd = normalize(-Cpos)
const right = normalize(cross(fwd, SVector(0.0, 0.0, 1.0)))   # = +Y
const down = cross(fwd, right)                                 # (right, down, fwd) right-handed
const F = 900.0
const CX, CY = 960.0 + 17.3, 540.0 - 11.7                      # physical display principal point

# physical display (x right, y down) of a world point
disp(P::SVector{2}) = disp(SVector(P[1], P[2], 0.0))
function disp(P::SVector{3})
    pc = SVector(dot(right, P - Cpos), dot(down, P - Cpos), dot(fwd, P - Cpos))
    return SVector(F * pc[1] / pc[3] + CX, F * pc[2] / pc[3] + CY)
end
# stored scale factors: row = y*sy, col = x*sx, sar = sy/sx
scales(sar) = sar >= 1 ? (1.0, 1 / sar) : (sar, 1.0)          # (sy, sx)
stored(P, sar) = (d = disp(P); (sy, sx) = scales(sar); SVector(d[2] * sy, d[1] * sx))   # (row, col)
# Fromage display (x, y) of a stored (row, col): the exact inverse of Spaces.to_stored
fdisplay(rc, sar) = (rc[2] * sar, rc[1])

# the true camera as a Fromage CameraModel, for a board frame with origin O, axes ei, ej (world, 3D)
function true_camera(O, ei, ej, cw, sar)
    sy, sx = scales(sar)
    Rf = vcat(down', right', fwd')                             # Fromage's camera frame: (row-dir, col-dir, depth)
    ek = -cross(ei, ej)                                        # det(Rf) = -1, so det(E) must be -1
    E = hcat(ei, ej, ek)
    Rm = SMatrix{3, 3}(Rf * E)
    @assert det(Rm) ≈ 1
    rv = RotationVec(RotMatrix(Rm))
    t = Rf * (O - Cpos) / cw
    return R.CameraModel(; R = SVector(rv.sx, rv.sy, rv.sz), t, frow = F * sy, fcol = F * sx,
        crow = CY * sy, ccol = CX * sx, k = (0.0, 0.0, 0.0))
end

# ---------------- the flat board ----------------
const CW = 0.04
const NY, NX = 10, 7                                           # inner corners along world Y (long) and X
cornerP(a, b) = SVector((b - (NX - 1) / 2) * CW, (a - (NY - 1) / 2) * CW, 0.0)   # a along Y, b along X

# The 8 possible orderings of the grid: origin corner and two in-plane axes (ei, ej), each ±X̂ or ±Ŷ.
X̂, Ŷ = SVector(1.0, 0, 0), SVector(0.0, 1, 0)
function orderings()
    out = []
    for (ei, ej) in ((Ŷ, X̂), (X̂, Ŷ)), si in (1, -1), sj in (1, -1)
        e_i, e_j = si * ei, sj * ej
        n1 = e_i == ±Ŷ ? NY : NX
        n2 = e_j == ±Ŷ ? NY : NX
        # origin = the corner from which ei and ej point inward
        O = sum(-(e == Ŷ || e == -Ŷ ? (NY - 1) / 2 : (NX - 1) / 2) * CW * e for e in (e_i, e_j))
        push!(out, (; e_i, e_j, n1, n2, O = SVector(O[1], O[2], 0.0)))
    end
    return out
end
±(a) = (a, -a)
Base.:(==)(a::SVector, t::Tuple) = any(==(a), t)

detQ(o) = sign(o.e_i[1] * o.e_j[2] - o.e_i[2] * o.e_j[1])    # handedness of (ei, ej) against world (X, Y)

# expected gauged real (y, x) of world P
function expected(P, C, N, dq)
    u = normalize(SVector(N[1] - C[1], N[2] - C[2]))
    uperp = SVector(-u[2], u[1])
    d = SVector(P[1] - C[1], P[2] - C[2])
    return SVector(-dot(d, u), -dq * dot(d, uperp))
end

# test points on the arena: a polar grid out to 1 m, plus the dots
testpts = vcat([SVector(ρ * cos(φ), ρ * sin(φ), 0.0) for ρ in 0.1:0.15:1.0 for φ in range(0, 2π; length = 13)[1:(end - 1)]],
    [SVector(0.0, 0.5, 0.0), SVector(0.0, -0.5, 0.0), SVector(0.0, 0.0, 0.0)])

function run_true_model(; sar, C, N, verbose = false)
    worst = 0.0
    rows = String[]
    for o in orderings()
        cam = true_camera(o.O, o.e_i, o.e_j, CW, sar)
        center = fdisplay(stored(C, sar), sar)
        north = fdisplay(stored(N, sar), sar)
        sy, sx = scales(sar)
        i2r, r2i = R._maps(cam; checker_width = CW, width = round(Int, 1920sx), height = round(Int, 1080sy), aspect = sar, center, north)
        # ungauged frame, for the board-frame claim: the corner (i,j) maps to (i*cw, j*cw)
        i2r0, _ = R._maps(cam; checker_width = CW, width = round(Int, 1920sx), height = round(Int, 1080sy), aspect = sar, center = fdisplay(stored(o.O, sar), sar), north = missing)
        P11 = o.O + CW * (o.e_i * 2 + o.e_j * 3)               # object corner (2, 3)
        board_err = norm(i2r0(stored(P11, sar)) - SVector(2CW, 3CW))
        err = maximum(norm(i2r(stored(P, sar)) - expected(P, C, N, detQ(o))) for P in testpts)
        rt = maximum(norm(r2i(i2r(stored(P, sar))) - stored(P, sar)) for P in testpts)
        worst = max(worst, err)
        push!(rows, @sprintf("  ei=%-12s ej=%-12s detQ=%+d  max|real-formula|=%.2e m  board(2,3) err=%.1e m  roundtrip=%.1e px",
            string(Tuple(Int.(o.e_i[1:2]))), string(Tuple(Int.(o.e_j[1:2]))), detQ(o), err, board_err, rt))
    end
    verbose && foreach(println, rows)
    return worst
end

println("== _maps with the TRUE camera model, center = proj(origin), north = proj((0, 0.5)) ==")
for sar in (1.0, 0.5, 10 / 11, 16 / 15, 64 / 45, 2.0)
    w = run_true_model(; sar, C = SVector(0.0, 0.0), N = SVector(0.0, 0.5), verbose = sar in (1.0, 2.0))
    @printf("sar = %.4f  worst |real - formula| over 8 orderings x %d points = %.2e m\n", sar, length(testpts), w)
end
println("\n== general center/north (C = (0.13, -0.21), N = (-0.4, 0.37)) ==")
for sar in (1.0, 0.5, 2.0)
    w = run_true_model(; sar, C = SVector(0.13, -0.21), N = SVector(-0.4, 0.37))
    @printf("sar = %.4f  worst = %.2e m\n", sar, w)
end

# explicit example values for the doc, sar = 1, ordering with detQ = +1 and -1
println("\n== example values, center = origin, north = (0, 0.5) ==")
for o in orderings()[[1, 2]]
    cam = true_camera(o.O, o.e_i, o.e_j, CW, 1.0)
    i2r, _ = R._maps(cam; checker_width = CW, width = 1920, height = 1080, aspect = 1.0,
        center = fdisplay(stored(SVector(0.0, 0, 0), 1.0), 1.0), north = fdisplay(stored(SVector(0.0, 0.5, 0), 1.0), 1.0))
    for P in (SVector(0.0, 0.5, 0), SVector(0.3, 0, 0), SVector(0.0, -0.5, 0), SVector(0.2, 0.1, 0))
        r = i2r(stored(P, 1.0))
        @printf("  detQ=%+d  world (X,Y)=(%+.2f,%+.2f) -> real (y,x)=(%+.6f,%+.6f)\n", detQ(o), P[1], P[2], r[1], r[2])
    end
end

# to_stored exactness
println("\n== to_stored(fdisplay(rc)) round trip ==")
for sar in (0.5, 10 / 11, 16 / 15, 64 / 45, 2.0, 1.0)
    e = maximum(maximum(abs.(SVector(Sp.to_stored(fdisplay(stored(P, sar), sar), sar)) - stored(P, sar))) for P in testpts)
    @printf("  sar=%.4f  max |to_stored(display) - stored| = %.1e px\n", sar, e)
end
