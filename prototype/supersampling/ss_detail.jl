# #292 detail: per-frame corner movement, map error vs truth, and the dots' analytic area centroid
using Serialization: deserialize
using Statistics: mean
using LinearAlgebra: norm
using Printf: @printf
ENV["RIG_LIB"] = "1"
include(joinpath(@__DIR__, "..", "baseline_rig.jl"))   # needs RIG_SAR matching SARTAG

const DIR = joinpath(@__DIR__, "out")
st(v) = isempty(v) ? (NaN, NaN) : (sqrt(mean(abs2, v)), maximum(abs, v))
tag = ENV["SARTAG"]
runs = [deserialize(joinpath(DIR, "sar$(tag)_ss$ss.jls")) for ss in (4, 8, 16, 32) if isfile(joinpath(DIR, "sar$(tag)_ss$ss.jls"))]

println("per-frame corner movement (RMS / max px), consecutive rates, and error vs truth at the highest rate")
for k in eachindex(runs[1].names)
    @printf("%-14s", runs[1].names[k])
    for (a, b) in zip(runs[1:(end - 1)], runs[2:end])
        (a.dets[k] === missing || b.dets[k] === missing) && (print("        —        "); continue)
        @printf("  %.3f / %.3f", st(norm.(a.dets[k] .- b.dets[k]))...)
    end
    r = runs[end]
    r.dets[k] === missing || @printf("   | err %.3f / %.3f", st([minimum(norm(d - t) for t in r.truth[k]) for d in r.dets[k]])...)
    println()
end

println("\nmap vs truth over the arena (mm RMS / max), each rate")
for r in runs
    r.maps === nothing && (println("SS $(r.ss): no maps (flat board missed)"); continue)
    truth = [V2(-100P[2], 100P[1]) for P in r.grid]
    ecb = [10norm(g - t) for (g, t) in zip(r.maps.from_checkerboard, truth)]
    eex = [10norm(g - t) for (g, t) in zip(r.maps.from_extrinsic, truth)]
    @printf("SS %2d   checkerboard %.3f / %.3f   extrinsic %.3f / %.3f\n", r.ss, st(ecb)..., st(eex)...)
end

# the area centroid of each dot's image, analytically: polygon centroid of the projected rim
function area_centroid(c)
    ps = [project(V3(c[1] + DOT_R * cos(θ), c[2] + DOT_R * sin(θ), 0)) for θ in range(0, 2π, 20001)[1:(end - 1)]]
    A = cx = cy = 0.0
    for i in eachindex(ps)
        p, q = ps[i], ps[mod1(i + 1, length(ps))]
        w = p[1] * q[2] - q[1] * p[2]
        A += w
        cx += (p[1] + q[1]) * w
        cy += (p[2] + q[2]) * w
    end
    return V2(cx / 3A, cy / 3A)
end
ac = sort([area_centroid(d) for d in DOTS], by = p -> p[2])
println("\ndots: area centroid of the projected disc vs projected centre: ",
    join((@sprintf("%.4f px", norm(a - p)) for (a, p) in zip(ac, runs[1].dotpx)), ", "))
for r in runs
    @printf("SS %2d  centroid − area centroid: %s\n", r.ss, join((@sprintf("%.4f px", norm(d - a)) for (d, a) in zip(r.dots, ac)), ", "))
end
