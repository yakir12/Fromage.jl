# Attribute the sar != 1 error of the fitted path: repeat `_rectification`'s body verbatim except that
# `fit_model` receives 1/sar (the direction #275 says is physical). Also the error restricted to the
# board footprint, and the fitted intrinsics against truth.
src = read(joinpath(dirname(abspath(PROGRAM_FILE)), "fitted.jl"), String)
include_string(Main, split(src, "println(\"== _rectification")[1])

function rect_with(fit_aspect; imgpointss, width, height, n_corners, sar, rp, center, north)
    objpoints = R.XYZ.(Tuple.(CartesianIndices((0:(n_corners[1] - 1), 0:(n_corners[2] - 1), 0:0))))
    m = R.fit_model((height, width), objpoints, imgpointss, n_corners, rp, fit_aspect)
    i = length(imgpointss)
    cam = R.CameraModel(; R = m.Rs[i], t = m.ts[i], m.frow, m.fcol, m.crow, m.ccol, m.k)
    i2r, _ = R._maps(cam; checker_width = CW, width, height, aspect = sar, center, north)
    return i2r, m
end
C, N = SVector(0.0, 0.0), SVector(0.0, 0.5)
board_pts = [cornerP(a, b) for a in 0:(NY - 1), b in 0:(NX - 1)]
o = orderings()[2]
for sar in (0.5, 10 / 11, 16 / 15, 64 / 45, 2.0), (label, fa) in (("as main (aspect)", sar), ("inverted (1/aspect)", 1 / sar))
    sy, sx = scales(sar)
    imgpointss = vcat(waved_views(sar; n1 = o.n1, n2 = o.n2), [extrinsic_view(o, sar)])
    i2r, m = rect_with(fa; imgpointss, width = round(Int, 1920sx), height = round(Int, 1080sy), n_corners = (o.n1, o.n2), sar, rp = 0,
        center = fdisplay(stored(C, sar), sar), north = fdisplay(stored(N, sar), sar))
    e_all = [norm(i2r(stored(P, sar)) - expected(P, C, N, detQ(o))) for P in testpts]
    e_b = [norm(i2r(stored(P, sar)) - expected(P, C, N, detQ(o))) for P in board_pts]
    @printf("sar=%.4f %-20s arena RMS %.2e m | board RMS %.2e m | frow %.1f (true %.1f) fcol %.1f (true %.1f)\n",
        sar, label, sqrt(sum(abs2, e_all) / length(e_all)), sqrt(sum(abs2, e_b) / length(e_b)), m.frow, F * sy, m.fcol, F * sx)
end
