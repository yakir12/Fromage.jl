# #292: compare the supersampling runs, per sar, against the highest rate and between consecutive rates
using Serialization: deserialize
using Statistics: mean
using LinearAlgebra: norm
using Printf: @printf
using StaticArrays: SVector
using Fromage: Fromage
const RX = Fromage.Rectifications
const OBJ = RX.XYZ.(Tuple.(CartesianIndices((0:6, 0:9, 0:0))))
# intrinsics refitted with aspect = 1/sar: fit_model's own sar convention is #275, kept out of this measurement
function refit(r)
    m = RX.fit_model((r.H, r.W), OBJ, [reshape(RX.RowCol.(Tuple.(d)), (7, 10)) for d in r.dets if d !== missing], (7, 10), 1, 1 / float(r.sar))
    return (; m.frow, m.fcol, m.crow, m.ccol, m.k)
end

const DIR = joinpath(@__DIR__, "out")
st(v) = isempty(v) ? (NaN, NaN) : (sqrt(mean(abs2, v)), maximum(abs, v))
nearest(d, truth) = minimum(norm(d - t) for t in truth)

function corner_moves(a, b)
    e = Float64[]
    for (da, db) in zip(a.dets, b.dets)
        (da === missing || db === missing) && continue
        append!(e, norm.(da .- db))
    end
    return e
end
cornerr(r) = [nearest(d, t) for (ds, t) in zip(r.dets, r.truth) if ds !== missing for d in ds]
pixdiff(a, b) = (d = [abs(Int(x) - Int(y)) for (fa, fb) in zip(a.frames, b.frames) for (x, y) in zip(fa, fb)];
    (maximum(d), count(>(0), d) / length(d), sqrt(mean(abs2, d))))

for sartag in ("1", "64_45", "2")
    runs = [deserialize(joinpath(DIR, "sar$(sartag)_ss$ss.jls")) for ss in (4, 8, 16, 32) if isfile(joinpath(DIR, "sar$(sartag)_ss$ss.jls"))]
    isempty(runs) && continue
    runs = [merge(r, (; fit = refit(r))) for r in runs]
    println("\n================ sar $(runs[1].sar), stored $(runs[1].W)×$(runs[1].H) ================")
    t = runs[1].truefit
    @printf("truth: frow %.3f fcol %.3f crow %.3f ccol %.3f k1 0\n", t.frow, t.fcol, t.crow, t.ccol)
    println("SS   render s  detected  corner err RMS/max px   frow       fcol       crow       ccol       k1          dot err px (L, R)")
    for r in runs
        f = r.fit
 isempty(r.names[ismissing.(r.dets)]) || println("   SS $(r.ss) missed: ", r.names[ismissing.(r.dets)])
        @printf("%2d   %7.1f   %2d/%2d     %.4f / %.4f       %9.4f  %9.4f  %9.4f  %9.4f  %+.6f   %.4f, %.4f\n",
            r.ss, r.trender, count(!ismissing, r.dets), length(r.dets), st(cornerr(r))..., f.frow, f.fcol, f.crow, f.ccol, f.k[1],
            (norm(d - p) for (d, p) in zip(r.dots, r.dotpx))...)
    end
    ref = runs[end]
    println("\nmovement against SS $(ref.ss) (stored px; maps in mm)")
    println("SS   pixels max/share/RMS grey   corners RMS/max px    |Δfrow|  |Δfcol|  |Δcrow|  |Δccol|  |Δk1|      dots max px   map cb RMS/max mm   map ex RMS/max mm")
    for r in runs[1:(end - 1)]
        pd = pixdiff(r, ref)
        cm = corner_moves(r, ref)
        df = (abs(r.fit.frow - ref.fit.frow), abs(r.fit.fcol - ref.fit.fcol), abs(r.fit.crow - ref.fit.crow), abs(r.fit.ccol - ref.fit.ccol), abs(r.fit.k[1] - ref.fit.k[1]))
        dm = maximum(norm.(r.dots .- ref.dots))
        hm = r.maps !== nothing && ref.maps !== nothing
        mcb = hm ? [10norm(a - b) for (a, b) in zip(r.maps.from_checkerboard, ref.maps.from_checkerboard)] : Float64[]
        mex = hm ? [10norm(a - b) for (a, b) in zip(r.maps.from_extrinsic, ref.maps.from_extrinsic)] : Float64[]
        @printf("%2d   %3d / %5.1f%% / %.3f      %.4f / %.4f       %.4f   %.4f   %.4f   %.4f   %.2e   %.4f        %.4f / %.4f     %.4f / %.4f\n",
            r.ss, pd[1], 100pd[2], pd[3], st(cm)..., df..., dm, st(mcb)..., st(mex)...)
    end
    println("consecutive corner movement (stored px RMS / max):")
    for (a, b) in zip(runs[1:(end - 1)], runs[2:end])
        @printf("  %2d → %2d   %.4f / %.4f\n", a.ss, b.ss, st(corner_moves(a, b))...)
    end
end
