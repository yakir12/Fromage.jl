# Experiment 2 (#293): a checkerboard rectification through rectifications.csv → verify →
# load_rectifications → build_rectification, on synthetic lossless media at sar 1, 4/3 and 1/2,
# compared against the builder rung (from_checkerboard called directly) and against analytic truth.
using Fromage
using FFMPEG: FFMPEG
using LinearAlgebra: svd, det, norm, Diagonal
using StaticArrays: SVector, SMatrix
using Statistics: mean
const VRect = Fromage.VerifyRectifications
const R = Fromage.Rectifications

const SS = 4                                  # 4×4 supersampling per stored pixel
const SQ = 4.0                                # checker square, cm
const NC = (10, 7)                            # inner corners along u, v
const HALF = SQ .* (NC .+ 1) ./ 2             # checker area half-extent (22, 16)
const MARGIN = SQ                             # one-square white margin

Rx(a) = SMatrix{3, 3}(1, 0, 0, 0, cos(a), sin(a), 0, -sin(a), cos(a))
Ry(b) = SMatrix{3, 3}(cos(b), 0, -sin(b), 0, 1, 0, sin(b), 0, cos(b))

# board plane (u, v) cm, centred → display (x, y), 0-based pixel centres
function homography(f, cx, cy, a, b, D)
    Rm = Rx(deg2rad(a)) * Ry(deg2rad(b))
    K = SMatrix{3, 3}(f, 0, 0, 0, f, 0, cx, cy, 1)
    return K * hcat(Rm[:, 1], Rm[:, 2], SVector(0.0, 0.0, D))
end

function reflectance(u, v)
    (abs(u) > HALF[1] + MARGIN || abs(v) > HALF[2] + MARGIN) && return 0.5     # floor
    (abs(u) > HALF[1] || abs(v) > HALF[2]) && return 1.0                       # white margin
    return isodd(floor(Int, (u + HALF[1]) / SQ) + floor(Int, (v + HALF[2]) / SQ)) ? 1.0 : 0.0
end

# stored (row, col) centre coords → display: a physical, edge-aligned squeeze of the x axis
disp_x(c, sar) = sar * (c + 0.5) - 0.5
stored_col(x, sar) = (x + 0.5) / sar - 0.5

function render(H, W, Hh, sar)
    Hinv = inv(H)
    img = Matrix{UInt8}(undef, Hh, W)
    Threads.@threads for c in 0:(W - 1)
        for r in 0:(Hh - 1)
            acc = 0.0
            for i in 1:SS, j in 1:SS
                rs = r - 0.5 + (i - 0.5) / SS
                cs = c - 0.5 + (j - 0.5) / SS
                p = Hinv * SVector(disp_x(cs, sar), rs, 1.0)
                acc += reflectance(p[1] / p[3], p[2] / p[3])
            end
            img[r + 1, c + 1] = round(UInt8, 255 * acc / SS^2)
        end
    end
    return img
end

const POSES = [(0, 0, 60), (25, 0, 60), (-25, 0, 60), (0, 25, 60), (0, -25, 60), (15, 15, 65), (40, 5, 70)]  # last = extrinsic

corners_uv() = [SVector(-HALF[1] + SQ * i, -HALF[2] + SQ * j) for i in 1:NC[1], j in 1:NC[2]]

function make_media(dir, name, W, Hh, sar)
    Wd = W * sar                              # Fromage display width
    s = Wd / 1920                             # same optics relative to the display frame
    f, cx, cy = 900s * 1.0, (Wd / 2 + 13s), (Hh / 2 - 7s)
    Hs = [homography(f, cx, cy, p...) for p in POSES]
    raw = joinpath(dir, "$name.raw")
    open(raw, "w") do io
        for H in Hs
            write(io, permutedims(render(H, W, Hh, sar)))
        end
    end
    sarstr = "$(numerator(sar))/$(denominator(sar))"
    FFMPEG.ffmpeg_exe(`-y -loglevel error -f rawvideo -pix_fmt gray -s $(W)x$Hh -r 1 -i $raw -vf setsar=$sarstr -c:v libx264 -qp 0 -pix_fmt gray $(joinpath(dir, "$name.mp4"))`)
    rm(raw)
    # true stored (row, col) of every inner corner in the extrinsic frame
    He = Hs[end]
    truth = map(corners_uv()) do uv
        p = He * SVector(uv[1], uv[2], 1.0)
        x, y = p[1] / p[3], p[2] / p[3]
        (uv = uv, display = SVector(x, y), stored = SVector(y, stored_col(x, sar)))
    end
    return truth
end

# rigid (rotation + translation, and reflection allowed) Procrustes residual, RMS
function procrustes_rms(A, B)          # rows are points
    a = A .- mean(A; dims = 1)
    b = B .- mean(B; dims = 1)
    U, _, V = svd(b' * a)
    Q = U * V'                          # may be a reflection: real is (y, x)
    return sqrt(mean(sum(abs2, a * Q' .- b; dims = 2))), det(Q)
end

function main_experiment()
    root = mktempdir()
    for (name, W, Hh, sar) in (("sq", 1920, 1080, 1 // 1), ("hdv", 1440, 1080, 4 // 3), ("field", 1920, 540, 1 // 2))
        dir = joinpath(root, name)
        mkpath(dir)
        t0 = time()
        truth = make_media(dir, "board", W, Hh, sar)
        render_s = time() - t0
        # centre/north from the exact projection of two board points, rounded to display Ints as the csv demands
        cen = truth[5, 4].display
        nor = truth[5, 7].display
        cen_i, nor_i = round.(Int, cen), round.(Int, nor)
        open(joinpath(dir, "rectifications.csv"), "w") do io
            println(io, "rectification_id,file,extrinsic,intrinsic_start,intrinsic_stop,temporal_step,center,north")
            println(io, "full,board.mp4,6,0,5,1,,")
            println(io, "extr,board.mp4,6,,,,,")
            println(io, "gauged,board.mp4,6,0,5,1,\"($(cen_i[1]), $(cen_i[2]))\",\"($(nor_i[1]), $(nor_i[2]))\"")
        end
        open(joinpath(dir, "runs.csv"), "w") do io      # verify/main validate both files; every rectification must be used
            println(io, "run_id,rectification_id,file")
            for id in ("full", "extr", "gauged")
                println(io, "r_$id,$id,board.mp4")
            end
        end
        v = verify(dir; results_dir = joinpath(root, "out_$name"))
        df = v.rectifications
        println("\n=== $name: stored $(W)×$Hh, sar $sar (render $(round(render_s; digits = 1)) s) ===")
        show(stdout, MIME"text/plain"(), df[:, [:rectification_id, :aspect, :width, :height, :yadif, :blur, :n_corners, :checker_width, :temporal_step, :radial_parameters, :center, :north, :issues]]; allcols = true)
        println()
        println("runs issues: ", v.runs.issues)
        cs = VRect.load_rectifications(dir, joinpath(dir, "rectifications.csv"); defaults = (;), results_dir = joinpath(root, "out2_$name"), progress = false)
        for c in cs
            println(typeof(c), " ", c.rectification_id, " source=", c.source)
        end
        built = Dict(c.rectification_id => Fromage.build_rectification(c) for c in cs)
        # the builder rung: the same keywords, typed by hand
        file = realpath(joinpath(dir, "board.mp4"))
        direct = R.from_checkerboard(;
            file, extrinsic = 6.0, intrinsic_start = 0.0, intrinsic_stop = 5.0, temporal_step = 1.0,
            yadif = false, blur = 1.0, width = W, height = Hh, n_corners = (7, 10), checker_width = 4.0,
            aspect = Float64(sar), radial_parameters = 1, center = missing, north = missing
        )
        direct_exact = R.from_checkerboard(;
            file, extrinsic = 6.0, intrinsic_start = 0.0, intrinsic_stop = 5.0, temporal_step = 1.0,
            yadif = false, blur = 1.0, width = W, height = Hh, n_corners = (7, 10), checker_width = 4.0,
            aspect = Float64(sar), radial_parameters = 1, center = cen, north = nor      # sub-pixel, impossible through the csv
        )
        inverted = R.from_checkerboard(;
            file, extrinsic = 6.0, intrinsic_start = 0.0, intrinsic_stop = 5.0, temporal_step = 1.0,
            yadif = false, blur = 1.0, width = W, height = Hh, n_corners = (7, 10), checker_width = 4.0,
            aspect = Float64(1 / sar), radial_parameters = 1, center = missing, north = missing   # #275's control
        )
        pts = [t.stored for t in truth]
        same = maximum(norm(built["full"].image2real(p) - direct.image2real(p)) for p in pts)
        println("max |gateway − builder rung| on the extrinsic corners (cm): ", same)
        uv = reduce(vcat, [t.uv' for t in truth])
        for (id, rect) in (("full", built["full"]), ("extr", built["extr"]), ("gauged", built["gauged"]), ("direct_exact_gauge", direct_exact), ("aspect=1/sar (#275)", inverted))
            mapped = reduce(vcat, [collect(rect.image2real(p))' for p in pts])
            rms, d = procrustes_rms(uv, mapped)
            println(rpad(id, 20), " Procrustes RMS residual (mm) = ", round(10rms; sigdigits = 3), "   det = ", round(d; digits = 3))
        end
        # the gauge: where does the true centre point land, and in which direction is north?
        for (id, rect) in (("gauged(csv Int)", built["gauged"]), ("direct(exact)", direct_exact))
            c0 = rect.image2real(truth[5, 4].stored)
            n0 = rect.image2real(truth[5, 7].stored)
            println(rpad(id, 18), " centre→", round.(c0; digits = 4), " cm   north direction (deg from +axis 1)=", round(rad2deg(atan(n0[2] - c0[2], n0[1] - c0[1])); digits = 3))
        end
        println("csv centre/north (display, Int): ", cen_i, " ", nor_i, "   exact: ", round.(cen; digits = 3), " ", round.(nor; digits = 3))
    end
end

main_experiment()
