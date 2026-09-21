# The builder rung (#294, #301): Fromage's `from_checkerboard` and `from_extrinsic` called directly on
# a rig's video, as the csv would call them (`blur = 1.0`, and the detector flags Fromage ships), and
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
using Random: Xoshiro
using StaticArrays: SVector

"The csv's `blur` default (#293), which the builder rung passes too."
const BLUR = 1.0

"The board's inner corners as Fromage counts them: `(short, long)`."
const N_CORNERS = reverse(SQUARES .- 1)

"The default number of radial coefficients `from_checkerboard` fits (#289)."
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
corner_errors(f::Failure, truth) = f
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
intrinsics(m, truths) = (; m.frow, m.fcol, m.crow, m.ccol, k1 = m.k[1], k2 = m.k[2], k3 = m.k[3])
intrinsics(::Failure, truths) = map(_ -> missing, truths)


# each fitted term against its truth; a failed fit has none
function intrinsic_rows(ctx, cam::Camera, fitted)
    rows = Row[]
    truths = intrinsic_truth(cam)
    for ((term, truth), value) in zip(pairs(truths), intrinsics(fitted, truths))
        unit = startswith(String(term), "k") ? "" : "stored px"
        for (statistic, v) in (("fitted", value), ("truth", truth), ("error", value - truth))
            push!(rows, row(ctx; quantity = "intrinsics", split = String(term), statistic, value = v, unit, status = status_of(fitted)))
        end
    end
    return rows
end

# A fit's rows: its intrinsics, and its map in the four splits. A fit is its rectification and its
# camera model, either of which may be a `Failure`: without the flat board there is no map, and still
# the calibration frames' intrinsics (#294).
fit_rows(ctx, cam, g, fit) = [intrinsic_rows(ctx, cam, fit.model); map_rows(ctx, rect_errors(fit.rect, cam, g))]

rect_errors(rect, cam, g) = map_errors(rect.image2real, cam, g)
rect_errors(f::Failure, cam, g) = f

map_rows(ctx, errors) = reduce(vcat, [stat_rows(ctx, "map", split, "mm", e) for (split, e) in errors])
map_rows(ctx, f::Failure) = reduce(vcat, [stat_rows(ctx, "map", split, "mm", f) for split in MAP_SPLITS])

"""
    separation_error(image2real, dots) -> Float64

How far the distance between the two dots, found by the simulation's own detector at stored
`(row, col)` `dots` and mapped by `image2real`, is from the true 1 m, in mm (signed).
"""
function separation_error(image2real, dots)
    truth = 1000norm(DOT_CENTRES[1] - DOT_CENTRES[2])
    return MM_PER_REAL * norm(image2real(dots[1]) - image2real(dots[2])) - truth
end

separation_rows(ctx, rect, dots) = separation_row(ctx, separation_error(rect.image2real, dots))
separation_rows(ctx, f::Failure, dots) = separation_row(ctx, f)
separation_rows(ctx, rect, f::Failure) = separation_row(ctx, f)
separation_rows(ctx, f::Failure, ::Failure) = separation_row(ctx, f)
function separation_row(ctx, error)
    return [
        row(
            ctx; quantity = "dot separation", split = "centroids", statistic = "error",
            value = value_of(error), unit = "mm", status = status_of(error),
        ),
    ]
end

"""
    measure_builders(rig_name, cam::Camera, poses, file, inputs, radial_parameters) -> Vector{Row}

The builder rung's rows for the rig whose video `file` (from [`cached_video`](@ref)) holds its 28
board `poses` (as [`board_poses`](@ref) returns them, or [`jittered`](@ref)), frames 0–27 with the
flat board last, and the rig with no board as frame 28.
"""
function measure_builders(rig_name, cam::Camera, poses, file, inputs, radial_parameters)
    return measure_rung(rig_name, "builders", cam, poses, file, inputs, radial_parameters) do g, detected
        builder_fits(cam, g, file, filter(is_found, detected[1:(end - 1)]), detected[end], radial_parameters)
    end
end

function rung_inputs(cam::Camera, poses, file)
    flat, no_board = lastindex(poses) - 1, lastindex(poses)
    g = Gauge(cam)
    dots = detected_dots(cam, file, no_board)
    vf = _vf(missing, BLUR)
    detected = tmap(k -> frame_corners(cam, file, k, vf), 0:flat)
    errors = [corner_errors(d, fromage_corners(cam, p.board)) for (p, d) in zip(poses, detected)]
    found = filter(!is_failure, errors)
    all_errors, flat_errors = isempty(found) ? Failure("not detected") : reduce(vcat, found), errors[end]
    return (; g, dots, detected, all_errors, flat_errors)
end

"""
    measure_rung(fit_builder, rig_name, rung, cam::Camera, poses, file, inputs, radial_parameters) -> Vector{Row}

Measure one rung's shared detections, controls and Fromage fits. `fit_builder` receives the gauge
and detected corner frames and must return the two builder fits whose maps and camera models the
rung reports.
"""
function measure_rung(fit_builder, rig_name, rung, cam::Camera, poses, file, inputs, radial_parameters)
    (; g, dots, detected, all_errors, flat_errors) = inputs
    flat = lastindex(poses) - 1
    ctx = (; rig = rig_name, rung)
    rows = self_check_rows(ctx, cam, file, poses)
    append!(rows, dot_rows(ctx, cam, dots))

    measured = (; ctx..., builder = missing, section = "fromage")
    for (p, d) in zip(poses, detected)
        push!(
            rows, row(
                measured; quantity = "detection", split = p.name, statistic = "detected",
                value = is_found(d), unit = "frame", status = status_of(d),
            )
        )
    end
    push!(rows, row(measured; quantity = "detection", split = "all", statistic = "detected", value = count(is_found, detected), unit = "frames"))
    for (split, e) in (("all frames", all_errors), ("flat board", flat_errors))
        append!(rows, stat_rows(measured, "corners", split, "stored px", distances(e, 1)))
        # an anamorphic detector error is anisotropic in stored px (#294)
        cam.sar == 1 || append!(rows, stat_rows(measured, "corners", split, "display px", distances(e, cam.sar)))
    end

    fits = fit_builder(g, detected)
    for (builder, fit) in pairs(fits)
        at = (; ctx..., builder = String(builder), section = "fromage")
        append!(rows, fit_rows(at, cam, g, fit))
        append!(rows, separation_rows(at, fit.rect, dots))
    end

    # the controls: the same fits on analytic corners
    truth = [fromage_corners(cam, p.board) for p in poses]
    checkerboard = analytic_fit(cam, g, truth, radial_parameters)
    control = (; ctx..., section = "control")
    append!(rows, fit_rows((; control..., builder = "from_checkerboard"), cam, g, checkerboard))
    append!(rows, analytic_control_rows(ctx, checkerboard.rect, cam, g))
    # on exact corners the single-view fit diverges (#291), so it gets the detector's noise
    σ = noise(flat_errors)
    seeds = map(CONTROL_SEEDS) do seed
        fit_rows((; control..., builder = "from_extrinsic"), cam, g, noisy_fit(cam, g, truth[end], σ, seed))
    end
    append!(rows, aggregate_seeds(seeds))
    return rows
end

# The keywords every builder takes that come from the rig rather than from its video. Splatted
# beside the call's own keywords, so the two sets of names must stay disjoint: a repeated keyword
# would silently win.
rig_keywords(cam::Camera, g::Gauge) = (;
    width = cam.width, height = cam.height, n_corners = N_CORNERS, checker_width = CHECKER_WIDTH,
    aspect = float(cam.sar), g.center, g.north,
)

# Fromage's camera model fitted to the views' corners, the extrinsic view last, as the builders fit it
camera_model(cam::Camera, views, radial_parameters) =
    fit_model((cam.height, cam.width), OBJECT_POINTS, views, N_CORNERS, radial_parameters, float(cam.sar))

# Each builder's rectification of the video `file`, and the camera model it fits, each of them or
# why there is none, given the corners of the calibration frames found and of the flat board (the
# extrinsic frame, the one after them): the builder fits the calibration frames it finds and drops
# the rest. Without the flat board neither builder is called, as both would throw; the calibration
# frames still have intrinsics.
function builder_fits(cam::Camera, g::Gauge, file, calibration, flat::Failure, radial_parameters)
    return (
        from_checkerboard = (rect = flat, model = attempt(() -> camera_model(cam, calibration, radial_parameters))),
        from_extrinsic = (rect = flat, model = flat),
    )
end
function builder_fits(cam::Camera, g::Gauge, file, calibration, flat_corners, radial_parameters)
    flat = length(board_poses(cam)) - 1
    call = (; file, extrinsic = float(flat), yadif = missing, blur = BLUR, rig_keywords(cam, g)...)
    return (
        from_checkerboard = (
            rect = attempt() do
                from_checkerboard(;
                    call..., intrinsic_start = 0.0, intrinsic_stop = float(flat - 1), temporal_step = 1.0,
                    radial_parameters,
                )
            end,
            model = attempt(() -> camera_model(cam, [calibration; [flat_corners]], radial_parameters)),
        ),
        from_extrinsic = (rect = attempt(() -> from_extrinsic(; call...)), model = attempt(() -> camera_model(cam, [flat_corners], 0))),
    )
end

# the rectification Fromage's builders would build on the views' corners, and the model they fit
function analytic_fit(cam::Camera, g::Gauge, views, radial_parameters)
    return (
        rect = attempt(() -> _rectification(; imgpointss = views, radial_parameters, rig_keywords(cam, g)...)),
        model = attempt(() -> camera_model(cam, views, radial_parameters)),
    )
end

# the lengths of the stored `(row, col)` offsets `e`, with columns stretched by `sar` into display px
distances(e, sar) = [norm(SVector(x[1], x[2] * sar)) for x in e]
distances(f::Failure, _) = f

# The standard deviation along each axis of Gaussian noise whose 2D RMS is the corner errors' `e`:
# the flat board's, the one view the extrinsic-only fit sees.
noise(e) = sqrt(sum(abs2 ∘ norm, e) / length(e) / 2)
noise(f::Failure) = f

# the extrinsic-only fit on the flat board's analytic corners plus that noise
noisy_fit(cam, g, flat, σ, seed) = analytic_fit(cam, g, [with_noise(flat, σ, seed)], 0)
noisy_fit(cam, g, flat, f::Failure, seed) = (rect = f, model = f)

# `corners`, each moved by Gaussian noise of standard deviation `σ` px along each axis
function with_noise(corners, σ, seed)
    rng = Xoshiro(seed)
    return [c + σ * SVector(randn(rng), randn(rng)) for c in corners]
end

# the self-check that the analytic control reproduces the truth
analytic_control_rows(ctx, rect, cam, g) = analytic_control_row(ctx, summarize(Dict(map_errors(rect.image2real, cam, g))["arena"]).RMS)
analytic_control_rows(ctx, f::Failure, cam, g) = analytic_control_row(ctx, f)
function analytic_control_row(ctx, rms)
    at = (; ctx..., builder = "from_checkerboard", section = "self-check")
    return [
        row(
            at; quantity = "analytic control", split = "arena", statistic = "RMS", value = value_of(rms), unit = "mm",
            status = status_of(rms), passed = passes(rms, CONTROL_TOLERANCE),
        ),
    ]
end

# The lossless round trip: the video's flat-board and empty frames, decoded, against a fresh render.
# Two frames rather than all 29, because a render is the slow part; any lossy step, or a cache
# serving a stale video, shows on these as on any.
function self_check_rows(ctx, cam::Camera, file, poses)
    at = (; ctx..., builder = missing, section = "self-check")
    rows = Row[]
    for (split, k, board) in (("flat board", lastindex(poses) - 1, last(poses).board), ("no board", lastindex(poses), nothing))
        decoded = decoded_frame(cam, file, k)
        value = Float64(maximum(abs.(Int.(decoded) .- Int.(render(cam, board)))))
        push!(rows, row(at; quantity = "round trip", split, statistic = "max", value, unit = "grey levels", passed = iszero(value)))
    end
    return rows
end

# The corners of the video's frame `k` (0-based) as the builders find them, or why there are none.
# Frame by frame, so one frame that throws is that frame's finding, not the whole rig's.
function frame_corners(cam::Camera, file, k, vf)
    corners = attempt(() -> get_corners(file, float(k), vf, cam.width, cam.height, N_CORNERS))
    return ismissing(corners) ? Failure("not detected") : corners
end
is_failure(x) = false
is_failure(::Failure) = true
is_found(d) = !is_failure(d)

# the video's frame `k` (0-based), as Fromage's reader decodes it, unfiltered
decoded_frame(cam::Camera, file, k) = _frame_at(file, float(k), missing, cam.width, cam.height)

# the dots the simulation's own detector finds on the video's frame `k`, or why there are not two
function detected_dots(cam::Camera, file, k)
    found = detect_dots(decoded_frame(cam, file, k))
    return length(found) == length(DOT_CENTRES) ? found : Failure("not detected")
end

# the dot detector's self-check: each dot against its area centroid
dot_rows(ctx, cam::Camera, dots) = dot_rows(ctx, [minimum(norm(d - area_centroid(cam, c)) for d in dots) for c in DOT_CENTRES])
dot_rows(ctx, cam::Camera, f::Failure) = dot_rows(ctx, f)
function dot_rows(ctx, e)
    at = (; ctx..., builder = missing, section = "self-check")
    worst = largest(e)
    return [
        stat_rows(at, "dot centroid", "centroids", "stored px", e);
        row(
            at; quantity = "dot detector", split = "centroids", statistic = "max", value = value_of(worst),
            unit = "stored px", status = status_of(worst), passed = passes(worst, DOT_TOLERANCE),
        )
    ]
end
largest(e) = maximum(e)
largest(f::Failure) = f
