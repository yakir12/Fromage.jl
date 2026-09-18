# The builder end to end below detection: `_rectification` fed analytic corners (waved views + the
# flat extrinsic board), then compared with the formula. Plus: integer rounding of center/north (csv
# path), and the pixel-index convention check (rendered + detected vs analytic).
src = read(joinpath(dirname(abspath(PROGRAM_FILE)), "gauge.jl"), String)
include_string(Main, split(src, "println(\"== _maps")[1])
using Rotations: RotXYZ
using Random: Xoshiro

# a board point in camera coordinates (right, down, fwd) -> stored (row, col), OpenCV 0-based
function proj_cam(pc, sar)
    sy, sx = scales(sar)
    x, y = F * pc[1] / pc[3] + CX, F * pc[2] / pc[3] + CY
    return SVector(y * sy, x * sx)
end
toRC(v) = SVector{2, Float32}(v)

# waved views: board centred on the optical axis at depth d, tilted about its in-plane axes
function waved_views(sar; n1 = NY, n2 = NX)
    views = Matrix{Fromage.Spaces.RowCol}[]
    for (a, b, d) in ((0, 0, 0.7), (35, 0, 0.7), (-35, 0, 0.7), (0, 35, 0.7), (0, -35, 0.7), (25, 25, 0.8),
                      (-25, 25, 0.8), (25, -25, 0.8), (-25, -25, 0.8), (45, 10, 0.9), (-10, 45, 0.9), (10, -45, 0.9))
        Rb = RotXYZ(deg2rad(a), deg2rad(b), 0.0)
        push!(views, [toRC(proj_cam(SVector(0.0, 0.0, d) + Rb * SVector((i - (n1 - 1) / 2) * CW, (j - (n2 - 1) / 2) * CW, 0.0), sar))
                      for i in 0:(n1 - 1), j in 0:(n2 - 1)])
    end
    return views
end
extrinsic_view(o, sar) = [toRC(stored(o.O + CW * (i * o.e_i + j * o.e_j), sar)) for i in 0:(o.n1 - 1), j in 0:(o.n2 - 1)]

println("== _rectification on analytic corners (Float32, like OpenCV's), center = proj(0,0), north = proj(0,0.5) ==")
C, N = SVector(0.0, 0.0), SVector(0.0, 0.5)
for sar in (1.0, 0.5, 10 / 11, 16 / 15, 64 / 45, 2.0), (k, o) in enumerate(orderings()[[1, 2]]), rp in (0, 1)
    sy, sx = scales(sar)
    imgpointss = vcat(waved_views(sar; n1 = o.n1, n2 = o.n2), [extrinsic_view(o, sar)])
    rect = R._rectification(; imgpointss, width = round(Int, 1920sx), height = round(Int, 1080sy),
        n_corners = (o.n1, o.n2), checker_width = CW, aspect = sar, radial_parameters = rp,
        center = fdisplay(stored(C, sar), sar), north = fdisplay(stored(N, sar), sar))
    errs = [norm(rect.image2real(stored(P, sar)) - expected(P, C, N, detQ(o))) for P in testpts]
    @printf("sar=%.4f detQ=%+d radial_parameters=%d  RMS %.2e m  max %.2e m\n", sar, detQ(o), rp, sqrt(sum(abs2, errs) / length(errs)), maximum(errs))
end

println("\n== center/north rounded to Int display pixels (what rectifications.csv can carry), true camera ==")
for sar in (1.0, 2.0, 0.5)
    o = orderings()[2]
    cam = true_camera(o.O, o.e_i, o.e_j, CW, sar)
    sy, sx = scales(sar)
    c = fdisplay(stored(C, sar), sar); n = fdisplay(stored(N, sar), sar)
    i2r, _ = R._maps(cam; checker_width = CW, width = round(Int, 1920sx), height = round(Int, 1080sy), aspect = sar,
        center = round.(Int, c), north = round.(Int, n))
    errs = [norm(i2r(stored(P, sar)) - expected(P, C, N, detQ(o))) for P in testpts]
    @printf("sar=%.1f  center display=(%.3f, %.3f) north display=(%.3f, %.3f)  RMS %.2e m  max %.2e m\n", sar, c..., n..., sqrt(sum(abs2, errs) / length(errs)), maximum(errs))
end
