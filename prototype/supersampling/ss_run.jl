# #292: one (sar, SS) configuration of the baseline rig, frozen pose set; dumps everything to a .jls
# Run: RIG_SAR=… RIG_SS=… RIG_CORNER_FRAC=0.2 RIG_LIB=1 SS_OUT=<file> julia --project=test ss_run.jl
using Serialization: serialize
ENV["RIG_LIB"] = "1"
include(joinpath(@__DIR__, "..", "baseline_rig.jl"))

function run_one()
    out = mktempdir()
    poses = Tuple{String, Board}[]
    for deg in -60:10:60
        push!(poses, ("e2 $deg", first(waved(:e2, deg))))
    end
    for deg in -50:10:50
        deg == 0 && continue
        push!(poses, ("e1 $deg", first(waved(:e1, deg))))
    end
    for (sx, sy) in ((-1, -1), (1, -1), (-1, 1), (1, 1))
        push!(poses, ("corner $sx $sy", first(corner(sx, sy))))
    end
    push!(poses, ("flat", FLAT))
    t0 = time()
    frames = [render(b) for (_, b) in poses]
    target = render(nothing)
    trender = time() - t0
    file = encode(joinpath(out, "board.mp4"), frames)
    tfile = encode(joinpath(out, "target.mp4"), [target])
    vf = RX._vf(missing, 1.0)
    nc = (7, 10)
    dets = [RX.get_corners(file, float(k - 1), vf, W, H, nc) for k in eachindex(poses)]
    truth = [[project(P) for P in inner_corners(b)] for (_, b) in poses]
    objpoints = RX.XYZ.(Tuple.(CartesianIndices((0:(nc[1] - 1), 0:(nc[2] - 1), 0:0))))
    ok = findall(!ismissing, dets[1:(end - 1)])
    imgs = [dets[k] for k in ok]
    flat_ok = dets[end] !== missing
    flat_ok && push!(imgs, dets[end])
    mfit = RX.fit_model((H, W), objpoints, imgs, nc, 1, float(SAR))
    center, north = display_xy(project(V3(0, 0, 0))), display_xy(project(V3(0, 0.5, 0)))
    common = (;
        file, extrinsic = float(length(poses) - 1), yadif = missing, blur = 1.0, width = W, height = H,
        n_corners = nc, checker_width = 4.0, aspect = float(SAR), center, north,
    )
    grid = [V2(X, Y) for X in -1:0.05:1, Y in -1:0.05:1 if hypot(X, Y) <= 1]
    gridpx = [project(V3(P[1], P[2], 0)) for P in grid]
    maps = flat_ok ? let
    rcb = RX.from_checkerboard(;
        common..., intrinsic_start = 0.0, intrinsic_stop = float(length(poses) - 2),
        temporal_step = 1.0, radial_parameters = 1
    )
    rex = RX.from_extrinsic(; common...)
    (
        from_checkerboard = [V2(rcb.image2real(p)) for p in gridpx],
        from_extrinsic = [V2(rex.image2real(p)) for p in gridpx],
    )
    end : nothing
    dots = sort(detect_dots(RX._frame_at(tfile, 0.0, missing, W, H)), by = p -> p[2])
    dotpx = sort([project(V3(d[1], d[2], 0)) for d in DOTS], by = p -> p[2])
    return (;
        sar = SAR, ss = SS, W, H, names = first.(poses), trender, frames, target,
        dets = [d === missing ? missing : V2.(vec(d)) for d in dets], truth,
        fit = (; mfit.frow, mfit.fcol, mfit.crow, mfit.ccol, k = mfit.k),
        truefit = (; frow = F, fcol = F / SAR, crow = CY, ccol = CX / SAR),
        grid, maps, dots, dotpx,
    )
end

r = run_one()
serialize(ENV["SS_OUT"], r)
println("sar $(r.sar) ss $(r.ss): rendered in $(round(r.trender, digits = 1)) s; detected $(count(!ismissing, r.dets))/$(length(r.dets)), missed $(r.names[ismissing.(r.dets)]); fit $(r.fit)")
