# PROTOTYPE — THROWAWAY (#291). Is the extrinsic-only fit on the baseline flat board ill-conditioned?
# Fits the single flat view on: Fromage's detected corners, the analytic corners, and the analytic
# corners plus Gaussian noise at the detector's own RMS — and prints the fitted f beside the map error.
# Run after baseline_rig.jl, pointing RIG_OUT at its output folder.
ENV["RIG_LIB"] = "1"
include("baseline_rig.jl")
using Random: Xoshiro, randn

file = joinpath(ENV["RIG_OUT"], "board.mp4")
nc = (7, 10)
fdet = RX.get_corners(file, 33.0, RX._vf(missing, 1.0), W, H, nc)
_, truth = corner_errors(fdet, FLAT)
center, north = display_xy(project(V3(0, 0, 0))), display_xy(project(V3(0, 0.5, 0)))
shared = (; width = W, height = H, n_corners = nc, checker_width = 4.0, aspect = float(SAR), center, north)
objpoints = RX.XYZ.(Tuple.(CartesianIndices((0:6, 0:9, 0:0))))
grid = [V2(X, Y) for X in -1:0.05:1, Y in -1:0.05:1 if hypot(X, Y) <= 1]
@printf("truth f %.1f, principal point (row, col) (%.1f, %.1f); OpenCV pins it at the frame centre\n", F, CY, CX)
function row(lbl, pts)
    m = RX.fit_model((H, W), objpoints, [pts], nc, 0, float(SAR))
    rect = RX._rectification(; imgpointss = [pts], radial_parameters = 0, shared...)
    e, pr = map_errors(rect, grid)
    @printf("%-28s f %8.1f  c (%.1f, %.1f)  map RMS %8.2f mm, max %8.2f mm, Procrustes RMS %8.2f mm\n",
        lbl, m.frow, m.crow, m.ccol, stats(e)[1], stats(e)[2], stats(pr)[1])
end
row("detected (blur 1)", fdet)
row("analytic", RX.RowCol.(truth))
σ = stats(first(corner_errors(fdet, FLAT)))[1] / sqrt(2)
for seed in 1:10
    rng = Xoshiro(seed)
    row("analytic + noise, seed $seed", [RX.RowCol(t + σ * V2(randn(rng), randn(rng))) for t in truth])
end
