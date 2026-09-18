# The builder rung (#294, #301): Fromage's `from_checkerboard` and `from_extrinsic` called directly on
# a rig's video, as the csv would call them (`blur = 1.0`, `CALIB_CB_FAST_CHECK` included, #288), and
# measured against the rig's truth; beside them the analytic-corner controls, and the simulation's
# own self-checks. Ported from `main` in `prototype/baseline-rig:prototype/baseline_rig.jl` and from
# `prototype/baseline-rig:prototype/probe_extrinsic.jl` (#291).
#
# The rung reaches into Fromage's internals on purpose: the frame reader and the corner detector the
# builders use, so the simulation counts detected frames itself (the builders drop an undetected
# frame silently, #293); `fit_model`, for the intrinsics the builders fit and do not return; and the
# builders' shared tail, for the controls.

using Fromage.Rectifications: XYZ, _frame_at, _rectification, _vf, fit_model, from_checkerboard, from_extrinsic, get_corners
using LinearAlgebra: norm
using OhMyThreads: tmap
using Random: Xoshiro, randn
using StaticArrays: SVector

"The csv's `blur` default (#293), which the builder rung passes too."
const BLUR = 1.0

"The board's inner corners as Fromage counts them: `(short, long)`."
const N_CORNERS = reverse(SQUARES .- 1)

"The radial coefficients `from_checkerboard` fits (#289)."
const RADIAL_PARAMETERS = 1

"The seeds of the noisy `from_extrinsic` control (#294)."
const CONTROL_SEEDS = 1:10

"How far a detected dot may sit from its area centroid, stored px, for the dot detector's self-check."
const DOT_TOLERANCE = 0.05

"""
The map error, RMS over the arena in mm, under which `from_checkerboard` on exact corners counts as
reproducing the truth: the analytic control's self-check. It sits at ≈ 0.003 mm on the baseline rig.
"""
const CONTROL_TOLERANCE = 0.01

"The board points Fromage fits against, in its own construction (`_rectification`)."
const OBJECT_POINTS = XYZ.(Tuple.(CartesianIndices((0:(N_CORNERS[1] - 1), 0:(N_CORNERS[2] - 1), 0:0))))

"""
    fromage_corners(cam::Camera, b::Board) -> Matrix{SVector{2, Float64}}

The analytic projections of `b`'s inner corners (see [`corner_projections`](@ref)), in the order
Fromage's detector returns them: `N_CORNERS`, the short axis first.
"""
fromage_corners(cam::Camera, b::Board) = permutedims(corner_projections(cam, b))

"""
    corner_errors(detected, truth) -> Vector{SVector{2, Float64}}

Each detected corner's offset from its analytic projection, stored `(row, col)` px, index for index.
The detector may return a board turned half a turn, which is the same grid: then the truth is too.
"""
function corner_errors(detected, truth)
    d = [SVector{2, Float64}(p) for p in detected]
    e = d .- truth
    turned = d .- reverse(truth)
    return vec(sum(norm, turned) < sum(norm, e) ? turned : e)
end

# the intrinsics against their truth, in stored px (`k` is unitless)
function intrinsic_truth(cam::Camera)
    return (
        frow = cam.f, fcol = cam.f / cam.sar, crow = cam.principal_point[2], ccol = cam.principal_point[1] / cam.sar,
        k1 = cam.k[1], k2 = cam.k[2], k3 = cam.k[3],
    )
end
intrinsics(m) = (; m.frow, m.fcol, m.crow, m.ccol, k1 = m.k[1], k2 = m.k[2], k3 = m.k[3])

function intrinsic_rows(ctx, cam::Camera, fitted)
    rows = Row[]
    for (term, truth) in pairs(intrinsic_truth(cam))
        unit = startswith(String(term), "k") ? "" : "stored px"
        value = fitted isa Failure ? missing : intrinsics(fitted)[term]
        status = fitted isa Failure ? fitted.status : "ok"
        for (statistic, v) in (("fitted", value), ("truth", truth), ("error", value - truth))
            push!(rows, row(ctx; quantity = "intrinsics", split = String(term), statistic, value = v, unit, status))
        end
    end
    return rows
end

# a fit's rows: its intrinsics, and its map in the four splits
fit_rows(ctx, cam, g, f::Failure) = [intrinsic_rows(ctx, cam, f); map_rows(ctx, f)]
fit_rows(ctx, cam, g, fit) = [intrinsic_rows(ctx, cam, fit.model); map_rows(ctx, map_errors(fit.rect.image2real, cam, g))]

map_rows(ctx, errors) = reduce(vcat, [stat_rows(ctx, "map", split, "mm", e) for (split, e) in errors])
map_rows(ctx, f::Failure) = reduce(vcat, [stat_rows(ctx, "map", split, "mm", f) for split in ("arena", "on board", "off board", "Procrustes")])

"""
    separation_error(image2real, dots) -> Float64

How far the distance between the two dots, found by the simulation's own detector at stored
`(row, col)` `dots` and mapped by `image2real`, is from the true 1 m, in mm (signed).
"""
function separation_error(image2real, dots)
    truth = 1000norm(DOT_CENTRES[1] - DOT_CENTRES[2])
    return MM_PER_REAL * norm(image2real(dots[1]) - image2real(dots[2])) - truth
end

function separation_rows(ctx, fit, dots)
    value, status = fit isa Failure ? (missing, fit.status) : dots isa Failure ? (missing, dots.status) :
        (separation_error(fit.rect.image2real, dots), "ok")
    return [row(ctx; quantity = "dot separation", split = "centroids", statistic = "error", value, unit = "mm", status)]
end

"""
    measure_builders(rig_name, cam::Camera, file) -> Vector{Row}

The builder rung's rows for the rig whose video `file` (from [`cached_video`](@ref)) holds its 28
board poses, frames 0–27 with the flat board last, and the rig with no board as frame 28.
"""
function measure_builders(rig_name, cam::Camera, file)
    poses = board_poses(cam)
    flat, no_board = lastindex(poses) - 1, lastindex(poses)
    g = Gauge(cam)
    ctx = (; rig = rig_name, rung = "builders")
    rows = self_check_rows(ctx, cam, file, poses)
    dots = detected_dots(cam, file, no_board)
    append!(rows, dot_rows(ctx, cam, dots))

    # detection and corners: the builders' own reader and detector, at the csv's blur
    vf = _vf(missing, BLUR)
    detected = tmap(k -> get_corners(file, float(k), vf, cam.width, cam.height, N_CORNERS), 0:flat)
    fromage = (; ctx..., builder = missing, section = "fromage")
    for (p, d) in zip(poses, detected)
        push!(rows, row(fromage; quantity = "detection", split = p.name, statistic = "detected", value = ismissing(d) ? 0.0 : 1.0, unit = "frame", status = ismissing(d) ? "not detected" : "ok"))
    end
    push!(rows, row(fromage; quantity = "detection", split = "all", statistic = "detected", value = count(!ismissing, detected), unit = "frames"))
    errors = [ismissing(d) ? SVector{2, Float64}[] : corner_errors(d, fromage_corners(cam, p.board)) for (p, d) in zip(poses, detected)]
    all_errors, flat_errors = reduce(vcat, errors), ismissing(detected[end]) ? Failure("not detected") : errors[end]
    for (split, e) in (("all frames", isempty(all_errors) ? Failure("not detected") : all_errors), ("flat board", flat_errors))
        append!(rows, stat_rows(fromage, "corners", split, "stored px", e isa Failure ? e : norm.(e)))
        # an anamorphic detector error is anisotropic in stored px (#294)
        cam.sar == 1 || append!(rows, stat_rows(fromage, "corners", split, "display px", e isa Failure ? e : [norm(SVector(x[1], x[2] * cam.sar)) for x in e]))
    end

    # the builders, as the csv calls them
    fits = ismissing(detected[end]) ? (Failure("not detected"), Failure("not detected")) : builder_fits(cam, g, file, detected)
    for (builder, fit) in zip(("from_checkerboard", "from_extrinsic"), fits)
        at = (; ctx..., builder, section = "fromage")
        append!(rows, fit_rows(at, cam, g, fit))
        append!(rows, separation_rows(at, fit, dots))
    end

    # the controls: the same fits on analytic corners
    truth = [fromage_corners(cam, p.board) for p in poses]
    checkerboard = attempt(() -> analytic_fit(cam, g, truth, RADIAL_PARAMETERS))
    control = (; ctx..., section = "control")
    append!(rows, fit_rows((; control..., builder = "from_checkerboard"), cam, g, checkerboard))
    append!(rows, analytic_control_rows(ctx, checkerboard, cam, g))
    # on exact corners the single-view fit diverges (#291), so it gets the detector's noise
    σ = flat_errors isa Failure ? flat_errors : sqrt(sum(abs2 ∘ norm, flat_errors) / length(flat_errors)) / sqrt(2)
    seeds = map(CONTROL_SEEDS) do seed
        noisy = σ isa Failure ? σ : attempt(() -> analytic_fit(cam, g, [with_noise(truth[end], σ, seed)], 0))
        fit_rows((; control..., builder = "from_extrinsic"), cam, g, noisy)
    end
    append!(rows, aggregate_seeds(seeds))
    return rows
end

# The keywords every builder takes that come from the rig rather than from its video
rig_keywords(cam::Camera, g::Gauge) = (;
    width = cam.width, height = cam.height, n_corners = N_CORNERS, checker_width = CHECKER_WIDTH,
    aspect = float(cam.sar), g.center, g.north,
)

# Fromage's camera model fitted to the views' corners, the extrinsic view last, as the builders fit it
camera_model(cam::Camera, views, radial_parameters) =
    fit_model((cam.height, cam.width), OBJECT_POINTS, views, N_CORNERS, radial_parameters, float(cam.sar))

# Each builder's rectification of the video `file`, and the model it fitted, or why it has none.
# `detected` holds the corners of every pose, the flat board's (the extrinsic frame) last and found:
# the calibration frames the builder finds are the ones it fits, as it drops the rest.
function builder_fits(cam::Camera, g::Gauge, file, detected)
    flat = lastindex(detected) - 1
    call = (; file, extrinsic = float(flat), yadif = missing, blur = BLUR, rig_keywords(cam, g)...)
    views = [collect(skipmissing(detected[1:(end - 1)])); [detected[end]]]
    checkerboard = attempt() do
        rect = from_checkerboard(; call..., intrinsic_start = 0.0, intrinsic_stop = float(flat - 1), temporal_step = 1.0, radial_parameters = RADIAL_PARAMETERS)
        (; rect, model = camera_model(cam, views, RADIAL_PARAMETERS))
    end
    extrinsic = attempt(() -> (rect = from_extrinsic(; call...), model = camera_model(cam, views[end:end], 0)))
    return checkerboard, extrinsic
end

# Fromage's fit, and the rectification its builders would build, on the views' corners
function analytic_fit(cam::Camera, g::Gauge, views, radial_parameters)
    rect = _rectification(; imgpointss = views, radial_parameters, rig_keywords(cam, g)...)
    return (; rect, model = camera_model(cam, views, radial_parameters))
end

# `corners`, each moved by Gaussian noise of standard deviation `σ` px along each axis
function with_noise(corners, σ, seed)
    rng = Xoshiro(seed)
    return [c + σ * SVector(randn(rng), randn(rng)) for c in corners]
end

# the self-check that the analytic control reproduces the truth
function analytic_control_rows(ctx, fit, cam, g)
    at = (; ctx..., builder = "from_checkerboard", section = "self-check")
    fit isa Failure && return [row(at; quantity = "analytic control", split = "arena", statistic = "RMS", value = missing, unit = "mm", status = fit.status, passed = false)]
    rms = summarize(last(first(map_errors(fit.rect.image2real, cam, g)))).RMS
    return [row(at; quantity = "analytic control", split = "arena", statistic = "RMS", value = rms, unit = "mm", passed = rms < CONTROL_TOLERANCE)]
end

# The lossless round trip: the video's flat-board and empty frames, decoded, against a fresh render.
# Two frames rather than all 29, because a render is the slow part; any lossy step, or a cache
# serving a stale video, shows on these as on any.
function self_check_rows(ctx, cam::Camera, file, poses)
    at = (; ctx..., builder = missing, section = "self-check")
    rows = Row[]
    for (split, k, board) in (("flat board", lastindex(poses) - 1, last(poses).board), ("no board", lastindex(poses), nothing))
        decoded = _frame_at(file, float(k), missing, cam.width, cam.height)
        value = Float64(maximum(abs.(Int.(decoded) .- Int.(render(cam, board)))))
        push!(rows, row(at; quantity = "round trip", split, statistic = "max", value, unit = "grey levels", passed = iszero(value)))
    end
    return rows
end

# the dots the simulation's own detector finds on the video's frame `k`, or why there are not two
function detected_dots(cam::Camera, file, k)
    found = detect_dots(_frame_at(file, float(k), missing, cam.width, cam.height))
    return length(found) == length(DOT_CENTRES) ? found : Failure("not detected")
end

# the dot detector's self-check: each dot against its area centroid
function dot_rows(ctx, cam::Camera, dots)
    at = (; ctx..., builder = missing, section = "self-check")
    dots isa Failure && return [row(at; quantity = "dot detector", split = "centroids", statistic = "max", value = missing, unit = "stored px", status = dots.status, passed = false)]
    e = [minimum(norm(d - area_centroid(cam, c)) for d in dots) for c in DOT_CENTRES]
    return [
        stat_rows(at, "dot centroid", "centroids", "stored px", e);
        row(at; quantity = "dot detector", split = "centroids", statistic = "max", value = maximum(e), unit = "stored px", passed = maximum(e) < DOT_TOLERANCE)
    ]
end
