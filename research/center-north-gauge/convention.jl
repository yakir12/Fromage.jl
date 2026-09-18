# Pixel-index convention of the corners Fromage fits to: render (pixel (r,c) centre = 0-based (r-1, c-1)),
# detect with Fromage's _detect_corners, compare with the analytic 0-based projection.
src = read(joinpath(dirname(abspath(PROGRAM_FILE)), "ordering.jl"), String)
include_string(Main, split(src, "println(\"n_corners")[1])
function project(cam, P, sar)
    sy, sx = scales(sar)
    v = SVector(P[1], P[2], 0.0) - cam.Cpos
    x = F * dot(cam.right, v) / dot(cam.fwd, v) + CX
    y = F * dot(cam.down, v) / dot(cam.fwd, v) + CY
    return SVector(y * sy, x * sx)
end
for sar in (1.0, 10 / 11)
    cam = camera(0.0)
    img = render(cam, SVector(0.0, 1.0), 0, sar)
    cs = R._detect_corners(reshape(img, 1, size(img)...), (10, 7))
    # the analytic corner nearest to each detected one (ordering-free)
    grid = [SVector((b - 3) * CW, (a - 4.5) * CW) for a in 0:9, b in 0:6]
    d = [minimum(norm(project(cam, P, sar) - SVector{2, Float64}(c)) for P in grid) for c in cs]
    shifted = [minimum(norm(project(cam, P, sar) .+ 1 - SVector{2, Float64}(c)) for P in grid) for c in cs]
    @printf("sar=%.3f  detected vs analytic 0-based: RMS %.3f px (max %.3f); vs 1-based: RMS %.3f px\n",
        sar, sqrt(sum(abs2, d) / length(d)), maximum(d), sqrt(sum(abs2, shifted) / length(shifted)))
end
