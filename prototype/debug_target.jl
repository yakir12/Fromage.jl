# PROTOTYPE DEBUG: render just the target frame for one seed and dump it.
ENV["PROTO_LIB"] = "1"
include(joinpath(@__DIR__, "prototype_trial.jl"))
using FFMPEG: FFMPEG

seed = parse(Int, ARGS[1])
t = draw_trial(seed)
R, C = camera_pose(t)
ϕ = 2π * rand(t.rng)
mid = t.aim + 0.3t.arena_r * SVector(cos(2π * rand(t.rng)), sin(2π * rand(t.rng)))
dirv = SVector(cos(ϕ), sin(ϕ))
halfmax = t.arena_r - t.dot_r - norm(mid)
half = min(t.sep / 2, max(halfmax, 5.0))
d1 = mid + half * dirv
d2 = mid - half * dirv
println("arena_r $(round(t.arena_r,digits=1)) mid $(round.(mid,digits=1)) half $(round(half,digits=1))")
for (nm, d) in (("d1", d1), ("d2", d2))
    p = project(t, R, C, V3(d[1], d[2], 0))
    println("  $nm world $(round.(d, digits=1)) -> stored $(p === nothing ? "BEHIND CAMERA" : string(round.(p, digits=1))) (frame $(t.h)x$(t.w))")
end
img = render(t, R, C, nothing, (d1, d2))
println("  rendered gray extrema: ", extrema(img))
pgm = joinpath(@__DIR__, "debug_target_$seed.pgm")
open(pgm, "w") do io
    write(io, "P5\n$(t.w) $(t.h)\n255\n")
    write(io, UInt8.(round.(clamp.(permutedims(img)[:], 0, 1) .* 255)))
end
run(`$(FFMPEG.ffmpeg()) -y -hide_banner -loglevel error -i $pgm $(splitext(pgm)[1] * ".png")`)
rm(pgm)
println("  dots detected: ", detect_dots(UInt8.(round.(clamp.(img, 0, 1) .* 255))))

# what is actually at the projected dot positions?
p1 = project(t, R, C, V3(d1[1], d1[2], 0))
i0, j0 = round(Int, p1[1]) + 1, round(Int, p1[2]) + 1
println("  patch around d1 (1-based [$i0,$j0]):")
for i in (i0 - 4):(i0 + 4)
    println("    ", join([lpad(round(img[i, j], digits = 2), 6) for j in (j0 - 4):(j0 + 4)]))
end
v = Float64.(vec(UInt8.(round.(clamp.(img, 0, 1) .* 255))))
println("  median $(median(v)) min $(minimum(v)) → threshold $(median(v) - 0.45 * (median(v) - minimum(v)))")
println("  mask pixels: ", count(UInt8.(round.(clamp.(img, 0, 1) .* 255)) .< (median(v) - 0.45 * (median(v) - minimum(v)))))
