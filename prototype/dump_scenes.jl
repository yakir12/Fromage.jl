# PROTOTYPE DEBUG: render the three kinds of frame for one seed and save them as PNGs.
ENV["PROTO_LIB"] = "1"
include(joinpath(@__DIR__, "prototype_trial.jl"))
using FFMPEG: FFMPEG

seed = parse(Int, ARGS[1])
scale = length(ARGS) > 1 ? ARGS[2] : "900"

t0 = draw_trial(seed)
R, C = camera_pose(t0)
t = t0

# dots, as run_trial places them
ϕ = 2π * rand(t.rng)
mid = t.aim + 0.3t.arena_r * SVector(cos(2π * rand(t.rng)), sin(2π * rand(t.rng)))
dirv = SVector(cos(ϕ), sin(ϕ))
half = min(t.sep / 2, max(t.arena_r - t.dot_r - norm(mid), 5.0))
d1, d2 = mid + half * dirv, mid - half * dirv

# board, grown until the flat pose is visible, as run_trial does
flat = nothing
for g in (1.0, 1.5, 2.25, 3.375)
    global t, flat
    t = merge(t0, (; checker = t0.checker * g))
    flat = sample_board(t, R, C; flat = true)
    flat === nothing || break
end
waved = sample_board(t, R, C; flat = false)

function save(img, name)
    pgm = joinpath(@__DIR__, "scene_$(seed)_$name.pgm")
    png = splitext(pgm)[1] * ".png"
    open(pgm, "w") do io
        write(io, "P5\n$(t.w) $(t.h)\n255\n")
        write(io, UInt8.(round.(clamp.(permutedims(img)[:], 0, 1) .* 255)))
    end
    run(`$(FFMPEG.ffmpeg()) -y -hide_banner -loglevel error -i $pgm -vf scale=$scale:-1 $png`)
    rm(pgm)
    println("  wrote $png")
    return png
end

println("seed $seed: $(t.w)×$(t.h), sar $(t.sar), fov $(round(rad2deg(t.fov), digits = 0))°, k1 $(round(t.k[1], digits = 3)), checker $(round(t.checker, digits = 1)) cm, dots $(round(2t.dot_r, digits = 1)) cm ⌀, separation $(round(norm(d1 - d2), digits = 2)) cm")
save(render(t, R, C, waved, ()), "waved")
save(render(t, R, C, flat, ()), "extrinsic")
target = render(t, R, C, nothing, (d1, d2))
save(target, "target")

# a zoom on one dot, nearest-neighbour so the pixels stay visible
p = project(t, R, C, V3(d1[1], d1[2], 0))
i0, j0 = round(Int, p[1]) + 1, round(Int, p[2]) + 1
r = 28
crop = target[max(1, i0 - r):min(t.h, i0 + r), max(1, j0 - r):min(t.w, j0 + r)]
let ch, cw = size(crop)
    pgm = joinpath(@__DIR__, "scene_$(seed)_dotzoom.pgm")
    open(pgm, "w") do io
        write(io, "P5\n$(size(crop, 2)) $(size(crop, 1))\n255\n")
        write(io, UInt8.(round.(clamp.(permutedims(crop)[:], 0, 1) .* 255)))
    end
    run(`$(FFMPEG.ffmpeg()) -y -hide_banner -loglevel error -i $pgm -vf scale=400:-1:flags=neighbor $(splitext(pgm)[1] * ".png")`)
    rm(pgm)
    println("  wrote dot zoom")
end
