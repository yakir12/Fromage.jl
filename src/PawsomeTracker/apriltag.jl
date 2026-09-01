# AprilTag-based tracking for drone footage: register out drone motion and rectify the beetle track
# into metric ground-plane coordinates (cm), in a single pass, using four coplanar tags as
# landmarks. This file holds the ground-plane geometry (pure and unit-tested), the detection and
# tracking loop, and the ROI local search. Registration is folded into the background stack's lazy
# index pipe (RegisteredWarp), so the tracker works in the shared reference frame — a static scene
# — rather than in native image space. Every fit uses all 16 tag corners, and the metric map is fit
# from all four tags jointly; see DESIGN-HISTORY.md for the measurements behind both.

using StaticArrays: SVector, SMatrix
using LinearAlgebra: svd, det, norm
using AprilTags: AprilTags, AprilTagDetector, freeDetector!
using ..Rectifications: i2r_centering_northing

# The tag families the AprilTag detector supports (`@enum TagFamilies tag36h11 tag25h9 tag16h5`),
# keyed by the `family` CSV value, and how many cells span each tag's black border corner to
# corner: the N×N data grid plus one black border cell on every side. tag36h11 is 6×6 data ⇒ 8,
# tag25h9 5×5 ⇒ 7, tag16h5 4×4 ⇒ 6. AprilTags reports each tag's four OUTER black-border corners
# (`.p`, as [col, row]; the tag's unit square [-1, 1] maps to them), so corner-to-corner in real
# units is `cells_across × cell_size`.
# One table, not two keyed alike: `CELLS_ACROSS` used to be a second Dict over the same keys, so a
# family added to one and not the other was a KeyError waiting at `canon_square`.
const APRIL_FAMILIES = Dict(
    "tag36h11" => (detector = AprilTags.tag36h11, cells = 8),
    "tag25h9"  => (detector = AprilTags.tag25h9,  cells = 7),
    "tag16h5"  => (detector = AprilTags.tag16h5,  cells = 6))

const APRIL_FAMILY_NAMES = sort!(collect(keys(APRIL_FAMILIES)))

# The sentence a user sees for an unrecognised family, in one place: it used to be written twice,
# once here and once in the verification path, and the two spellings had to be kept identical by
# hand.
unknown_family_message(family) =
    "unknown AprilTag family \"$family\" (supported: $(join(APRIL_FAMILY_NAMES, ", ")))"

# The canonical tag corners in real-world units, in the detector's `.p` order, for a tag of
# `family` whose single cell measures `cell` units. `CANON`/`TAG_SIZE_CM` are the default gauge —
# tag36h11 at 12 cm/cell ⇒ a 96 cm black-border square — on which the geometry unit tests are built.
function canon_square(family, cell)
    h = APRIL_FAMILIES[family].cells * cell / 2
    SVector{2, Float64}[SVector(-h, h), SVector(h, h), SVector(h, -h), SVector(-h, -h)]
end
const TAG_SIZE_CM = 96.0
const CANON = canon_square("tag36h11", 12.0)

# apply a 3×3 homography to a 2D point (perspective divide)
apply_h(H, p) = (v = H * SVector(p[1], p[2], 1.0); SVector(v[1] / v[3], v[2] / v[3]))

# Normalized (Hartley) DLT homography fitting `src[i] → dst[i]` from ≥ 4 correspondences, returned
# as an `SMatrix{3,3}`. Normalization (centre + isotropic scale, per point set) is what keeps the
# solve well-conditioned when the pixel coordinates are large and off-origin, as tag corners are.
function homography_dlt(src, dst)
    n = length(src)
    function norm_pts(pts)
        c = sum(pts) / n
        s = sqrt(2) / (sum(p -> norm(p - c), pts) / n)
        T = SMatrix{3, 3, Float64}(s, 0, 0, 0, s, 0, -s * c[1], -s * c[2], 1)
        return T, [SVector(s * (p[1] - c[1]), s * (p[2] - c[2])) for p in pts]
    end
    Ts, ns = norm_pts(src)
    Td, nd = norm_pts(dst)
    A = Matrix{Float64}(undef, 2n, 9)
    for i in 1:n
        x, y = ns[i]
        xp, yp = nd[i]
        A[2i-1, :] .= (-x, -y, -1, 0, 0, 0, xp*x, xp*y, xp)
        A[2i,   :] .= (0, 0, 0, -x, -y, -1, yp*x, yp*y, yp)
    end
    h = svd(A).V[:, end]                          # null space → the homography (up to scale)
    Hn = SMatrix{3,3,Float64}(h[1], h[4], h[7], h[2], h[5], h[8], h[3], h[6], h[9])  # row-major
    H = inv(Td) * Hn * Ts                         # undo the normalization
    H / H[3, 3]
end

# worst deviation (real units) of any tag edge from the true side length `side`, under an
# image→cm homography `M`
_worst_side(M, tag_corners, side = TAG_SIZE_CM) =
    maximum(abs(norm(apply_h(M, tc[i]) - apply_h(M, tc[mod1(i+1, 4)])) - side)
            for tc in tag_corners for i in 1:4)

# Rigid Procrustes (Kabsch): the best-fit rotation + translation, no scale, mapping point set `A`
# onto `B`, returned as a function. Used to pin the metric fit's global gauge each iteration.
function rigid_align(A, B)
    ma = sum(A) / length(A)
    mb = sum(B) / length(B)
    H = sum((B[i] - mb) * (A[i] - ma)' for i in eachindex(A))  # 2×2 cross-covariance
    F = svd(H)
    # One assignment, not an assign-then-maybe-reassign. `R` is captured by the closure below, so
    # writing to it twice makes Julia box it (`Core.Box`), which costs an allocation per call and
    # leaves the captured value untyped. The ternary picks the value once and the box goes away —
    # this is the only `Core.Box` the package had.
    R0 = F.U * F.Vt
    R = det(R0) < 0 ? F.U * SMatrix{2, 2, Float64}(1, 0, 0, -1) * F.Vt : R0   # reflection guard
    return p -> R * (p - ma) + mb
end

# Place the canonical square `canon` (no scaling — its size is known exactly) onto four measured cm
# points, giving the best-fit true square at that pose. This is how each tag's known metric geometry
# is imposed during the consensus fit: the same Kabsch solve as above, evaluated at `canon` itself.
place_square(D, canon = CANON) = map(rigid_align(canon, D), canon)

# Fit the metric map `M : image → ground cm` from all tags jointly. Bootstrap from one tag's
# corners, then alternate: place a true square on each tag's current cm estimate (Procrustes), pin
# the global gauge by rigidly mapping tag 1's square back onto the canonical square, and refit `M`
# from all 16 corners to those pinned squares (DLT). The gauge pin is essential; without it the
# iteration diverges under strong perspective. EVERY tag is tried as the bootstrap and the globally
# best result kept, since the convergence basin is sensitive to sub-pixel corner noise. Fit once per
# reference frame — a one-time few ms, not a per-frame cost.
#
# Returns `(M, worst_error)`: it computes, it does not decide. Whether that error is acceptable is
# the caller's policy (see METRIC_FIT_TOLERANCE), which lets `reference_frame` report a
# non-converged fit as an issue string rather than catch a throw from in here.
function fit_metric(tag_corners; canon = CANON, maxiter = 1000, tol = 1e-9)
    side = norm(canon[1] - canon[2])
    flat = reduce(vcat, tag_corners)
    # The first bootstrap doubles as the fallback result: `beste` starts at its UNREFINED error, so
    # if no refinement anywhere beats it, that fit is what comes back. It is therefore computed
    # before the loop — and reused when the loop reaches it, rather than fitted a second time.
    fit(boot) = (M = homography_dlt(collect(tag_corners[boot]), canon);
                 (M, _worst_side(M, tag_corners, side)))
    boots = eachindex(tag_corners)
    bestM, beste = fit(first(boots))
    for boot in boots
        M, e = boot == first(boots) ? (bestM, beste) : fit(boot)
        for _ in 1:maxiter
            sq = [place_square(SVector{2,Float64}[apply_h(M, p) for p in tc], canon) for tc in tag_corners]
            T = rigid_align(sq[1], canon)                     # pin gauge: tag 1 → canonical square
            G = reduce(vcat, [[T(g) for g in s] for s in sq])
            Mn = homography_dlt(flat, G)
            en = _worst_side(Mn, tag_corners, side)
            if en < beste
                bestM = Mn
                beste = en
            end
            if abs(e - en) < tol
                break
            end
            M = Mn
            e = en
        end
    end
    return bestM, beste
end

# Worst per-tag square error (in the calibration's real units) still accepted as a converged metric
# fit; beyond it the tags are taken to be non-coplanar or mis-detected. The message lives here too,
# so the throwing and the issue-string paths below word it identically.
const METRIC_FIT_TOLERANCE = 5.0
metric_fit_issue(err) = "AprilTag metric fit did not converge (worst square error $(round(err, digits = 2)) > $METRIC_FIT_TOLERANCE; in the calibration's real units); tags may be non-coplanar or mis-detected"

# The reference frame: the tag ids (their order fixes the corner alignment used every frame), the
# 16 reference-image corners, and the metric map `M : reference image → ground cm`.
struct ReferenceFrame
    ids::Vector{Int}
    corners::Vector{SVector{2, Float64}}          # flat 16, tag-major in `ids` order
    # The length parameter is not optional decoration: without it the type is a UnionAll, so the
    # matrix is boxed and every `ref.M * R` loses the static size. Same reason as RegisteredWarp.Hinvs.
    M::SMatrix{3, 3, Float64, 9}
end

# Direct construction from detected corners: this one throws on a non-converged fit, since a caller
# building a reference frame by hand has nowhere to put an issue string. The pipeline entry point
# (`reference_frame`) does the same check itself and returns the message instead.
function ReferenceFrame(ids::AbstractVector{<:Integer}, tag_corners; kw...)
    M, err = fit_metric(tag_corners; kw...)
    err > METRIC_FIT_TOLERANCE && error(metric_fit_issue(err))
    ReferenceFrame(collect(Int, ids), reduce(vcat, tag_corners), M)
end

# ---- the shared reference as a rectification -------------------------------------------------
# The AprilTag calibration is a rectification like any other (VerifyRectifications builds it from a
# `type = apriltag` calibs row and Fromage joins it to the runs that reference it). Unlike the video
# rectifications there is no fixed image→real map: the drone moves, so each run frame is registered
# to this ONE shared `reference` (established from the calibration's extrinsic frame; the tags are
# stationary across every run) before the fixed metric map takes it to ground cm. `image2real` is
# therefore not a pixel map but the cm→real gauge (centre/north) applied to `track_apriltag`'s metric
# output; `family` is the detector family the runs must be detected with; `ratio` is a representative
# cm-per-pixel scale (kept positive for the diagnostics/tests that read it).
struct ApriltagRectification{I}
    reference::ReferenceFrame
    family::AprilTags.TagFamilies
    image2real::I
    ratio::Float64
    width::Int
    height::Int
end

# family CSV value → detector enum; also the validity gate for the `family` column.
function april_family(family::AbstractString)
    entry = get(APRIL_FAMILIES, family, nothing)
    isnothing(entry) && error(unknown_family_message(family))
    return entry.detector
end

# Read the single frame at timestamp `t` (seconds), in the same orientation `track_apriltag` sees
# frames in, so reference and run corners correspond directly.
function read_frame_at(file, t)
    vid = open_gray_video(file)   # serialized open (openvideo isn't thread-safe); see OPENVIDEO_LOCK
    try
        read(vid)                 # prime a frame so gettime returns the stream's base time
        seek(vid, t + gettime(vid))
        return read(vid)
    finally
        close(vid)
    end
end

# Establish the shared reference frame from the calibration's extrinsic frame: detect ≥ `ntags` tags
# of `family`, take the `ntags` lowest ids, and fit the metric map from their known cell geometry.
#
# Returns the `ReferenceFrame`, or a `String` describing why one could not be built — an unsupported
# family, an unreadable frame, too few tags, corners that could not be re-read, or a metric fit that
# did not converge. Every one of those is a fact about the calibration the user gave us, not an
# exceptional condition, so it is reported rather than thrown.
function reference_frame(file, extrinsic, ntags, family, tag_cell_width)
    valid_apriltag_family(family) ||
        return unknown_family_message(family)
    # Serialize the WHOLE read + detect: the one-shot VideoIO read races under the callers' `tmap`,
    # and the AprilTag detector is not reentrant. Reference building is one-time setup over a handful
    # of calibs, so this costs essentially nothing.
    lock(APRILTAG_LOCK) do
        # VideoIO reports an unreadable/corrupt file, and a seek past the end, as a plain
        # ErrorException, so that is as narrow as this gets — it still excludes the
        # MethodError/BoundsError of a bug here, and InterruptException.
        img = try
            read_frame_at(file, extrinsic)
        catch e
            e isa ErrorException || e isa SystemError || e isa Base.IOError || rethrow()
            return "could not read the extrinsic frame: $e"
        end
        det = set_detector!(AprilTagDetector(april_family(family)))
        try
            tags = det(collect(img))                # already holding APRILTAG_LOCK
            length(tags) ≥ ntags || return "only $(length(tags)) of $ntags AprilTags detected at the extrinsic frame"
            ids = sort([t.id for t in tags])[1:ntags]
            tc = detect_tags(det, img, ids)         # re-enters the lock (re-entrant), fine
            isnothing(tc) && return "could not read all $ntags AprilTag corners at the extrinsic frame"
            M, err = fit_metric(tc; canon = canon_square(family, tag_cell_width))
            err > METRIC_FIT_TOLERANCE && return metric_fit_issue(err)
            ReferenceFrame(collect(Int, ids), reduce(vcat, tc), M)
        finally
            freeDetector!(det)
        end
    end
end

# A representative cm-per-pixel scale of the reference frame: the mean tag side in cm over its mean
# side in pixels. Only used where a positive scalar `ratio` is expected (diagnostics/tests) — the
# real image→ground map is the per-frame homography, not a single scale.
function reference_ratio(ref::ReferenceFrame)
    px = 0.0
    cm = 0.0
    for tc in Iterators.partition(ref.corners, 4)             # one tag's 4 corners at a time
        for i in 1:4
            px += norm(tc[i] - tc[mod1(i + 1, 4)])
            cm += norm(apply_h(ref.M, tc[i]) - apply_h(ref.M, tc[mod1(i + 1, 4)]))
        end
    end
    return cm / px
end

# The cm → real gauge: `track_apriltag` already maps each frame to metric ground cm (x, y); this
# applies the `center`/`north` origin and orientation, exactly as the video pipeline's centre/north
# does, and returns real coordinates as `(y, x)` (matching every other rectification's `image2real`,
# so `save2csv` unpacks them the same way). `center`/`north` are pixels in the reference (extrinsic)
# frame; a missing `center` defaults to the frame centre, a missing `north` leaves orientation alone.
function apriltag_image2real(M, center, north, width, height, aspect)
    # `center`/`north` are DISPLAY pixels (see Rectifications.fix_coordinate), while `M` maps STORED
    # reference pixels, so x is divided by aspect on the way in. The frame-centre default needs no
    # such conversion: the display centre and the stored centre are the same point (#130).
    c = ismissing(center) ? SVector{2, Float64}(width / 2, height / 2) : SVector{2, Float64}(center[1] / aspect, center[2])
    n = ismissing(north) ? missing : SVector{2, Float64}(north[1] / aspect, north[2])
    # `f` mirrors a video image2real: reference pixel (col, row) → real (y, x). Feeding it and the
    # gauge points to the shared centre/north helpers pins the SAME north convention as the video path.
    f = p -> (cm = apply_h(M, SVector(Float64(p[1]), Float64(p[2]))); SVector(cm[2], cm[1]))
    centering, northing = i2r_centering_northing(f, c, n)
    gauge = northing ∘ centering
    return cm -> gauge(SVector(Float64(cm[2]), Float64(cm[1])))     # raw cm (x, y) → gauged real (y, x)
end

# Build the AprilTag rectification from a verified `type = apriltag` calibs row.
# `aspect` has no default: the calibs gateway reads it from the video (or the csv) for every row,
# so a default here would be a second definition of a value the caller always has -- exactly the
# duplication #140/#141 were about. Square pixels are spelled `aspect = 1.0` at the call site.
function ApriltagRectification(; file, extrinsic, ntags, family, tag_cell_width, center, north,
        width, height, aspect)
    ref = reference_frame(file, extrinsic, ntags, family, tag_cell_width)
    # Building a rectification has nowhere to put an issue string, so the report becomes a throw
    # here. In the normal pipeline this is unreachable: VerifyRectifications ran
    # apriltag_extrinsic_issue over the same arguments first and rejected the row.
    ref isa String && error(ref)
    i2r = apriltag_image2real(ref.M, center, north, width, height, aspect)
    return ApriltagRectification(ref, april_family(family), i2r, reference_ratio(ref), width, height)
end

# ---- verification hooks (used by VerifyRectifications) ---------------------------------------
# The families the `family` column may name, and a cheap validity predicate for it.
valid_apriltag_family(family) = haskey(APRIL_FAMILIES, family)

# Does the extrinsic frame support a shared reference? Returns `nothing` on success or an issue
# string (unreadable frame, too few tags, non-coplanar / mis-detected tags), so it composes with the
# gateway's other checks. A plain type test, since `reference_frame` already reports those as
# strings — a genuine error propagates rather than being reformatted as a calibration issue.
function apriltag_extrinsic_issue(file, extrinsic, ntags, family, tag_cell_width)
    ref = reference_frame(file, extrinsic, ntags, family, tag_cell_width)
    return ref isa String ? ref : nothing
end

# Homography mapping the current frame's image to the reference image, from all 16 corners (already
# aligned to `ref.ids` order by the caller). The full image→cm map for a frame is `ref.M * register(…)`,
# which the tracking loop composes inline because it needs the registration separately for `inv`.
register(ref::ReferenceFrame, corners) = homography_dlt(corners, ref.corners)

# The lazy registration warp: the background stack's index transform, composing each slice's
# registration with the tracker's inverse scaling, so every slice is sampled in the SHARED REFERENCE
# frame's coordinates. Drone motion is thereby removed at lookup time — the per-pixel max/min
# background model sees a static scene — at the cost of one homography apply per lookup.
# `Hinvs[k]` maps reference (x, y) px → frame-k (x, y) px (i.e. `inv(register(...))`) and is mutated
# in place as the rolling window replaces slices; the WarpedView holds this same vector, so updates
# are visible immediately. Coordinate bridge: the stack works in scaled (row, col) ("canvas"), the
# homographies in (x, y) = (col, row) stored px — hence the flips.
struct RegisteredWarp <: Transformation
    scale::Float64
    # NB the length parameter: the abstract `SMatrix{3, 3, Float64}` boxes every per-lookup load,
    # costing two orders of magnitude in detect's background reduce
    Hinvs::Vector{SMatrix{3, 3, Float64, 9}}
end
function (w::RegisteredWarp)(x::SVector{3})
    p = apply_h(w.Hinvs[Int(x[3])], SVector(x[2], x[1]) / w.scale)
    return SVector(p[2], p[1], x[3])
end

# the per-slice canvas → raw-frame (row, col) mapping (RegisteredWarp's 2D core), as a closure
# for the registered protect_target
canvas2raw(Hinv, scale) = rc -> (p = apply_h(Hinv, SVector(rc[2], rc[1]) ./ scale); (p[2], p[1]))

# raw px padded around the protected target region, absorbing the one frame of drone motion the
# registered protect_target approximates over (see its docstring in PawsomeTracker.jl)
const PROTECT_PAD = 5

# ============================================================================================
# Detection and the single-pass tracking loop.
# ============================================================================================

# The AprilTag detector needs a plain Gray{N0f8}/UInt8 matrix (not the Gray{Float32} background
# stack), so detection always runs on the raw frame. Whole-frame detection is used only to establish
# the reference and to relocate the (stationary) tags in a run's first frame; every frame after that
# goes through the per-tag local search below.
function set_detector!(det; nthreads = 1)
    det.nThreads = nthreads
    det.quad_decimate = 1.0
    det.quad_sigma = 0.0
    det.refine_edges = 1
    det.decode_sharpening = 0.25
    return det
end

# Every detection call goes through this, serializing them process-wide: the C detector is not
# reentrant (see APRILTAG_LOCK).
detect_locked(det, img) = lock(() -> det(img), APRILTAG_LOCK)

# Detect and return the 16 corners grouped per tag, aligned to `ids` order (each tag's `.p` corners
# as [col, row]); `nothing` if any expected id is absent. `SVector`-typed so the geometry consumes
# them directly.
function detect_tags(det, img, ids)
    tags = detect_locked(det, collect(img))
    byid = Dict(t.id => t for t in tags)
    all(haskey(byid, i) for i in ids) || return nothing
    [SVector{2,Float64}[SVector(p[1], p[2]) for p in byid[i].p] for i in ids]
end

# tag geometry is (x, y) = (col, row); the DoG tracker works in (row, col). This bridges the two.
img_to_cm(H, rc) = apply_h(H, SVector(rc[2], rc[1]))                       # (row,col) px → cm

# Resolve the initial guess in CANVAS coordinates. `start_location` is the target's (x, y)
# display-pixel position in the run's first frame — NATIVE space — while the stack lives in
# reference space, so the guess crosses the seed frame's registration `seedR` (native stored
# (col, row) → reference → scaled (row, col)). The seed may lag the first frame by a few tag-less
# frames; the drift is those frames' drone motion, well within the search window. The `missing`
# (centre search) case already operates on the reference-space stack and needs no mapping.
apriltag_guess(start_location::Missing, stack, vid, darker_target, target_width, initial_search_factor, subtract, _) =
    get_guess(start_location, stack, vid, darker_target, target_width, initial_search_factor, subtract)
function apriltag_guess(start_xy::NTuple{2, Int}, _, vid, _, _, _, _, seedR)
    x, y = start_xy
    p = apply_h(seedR, SVector(x / vid.sar, Float64(y)))
    return round.(Int, vid.scale .* (p[2], p[1]))
end

# ---- local ROI search --------------------------------------------------------------------------
# AprilTag detection cost scales with pixels, so after the reference frame each tag is searched in a
# small box around where it was last seen rather than over the whole frame. Detecting on a crop
# reproduces the full-frame corners to better than 0.1 px, so this is a pure speedup. The box grows
# and re-searches until the tag is found or spans the whole frame, degrading gracefully to
# full-frame detection when the drone jumps.
const ROI_MARGIN = 40      # px padded around a tag's corners to form its search box
const ROI_GROW = 250       # px the box expands on each side when the tag isn't found

# search box (r1, c1, r2, c2) around a tag's `corners` ([col,row]), padded and clamped to the frame
function tag_box(corners, sz)
    cols = getindex.(corners, 1); rows = getindex.(corners, 2)
    (clamp(floor(Int, minimum(rows)) - ROI_MARGIN, 1, sz[1]), clamp(floor(Int, minimum(cols)) - ROI_MARGIN, 1, sz[2]),
     clamp(ceil(Int, maximum(rows)) + ROI_MARGIN, 1, sz[1]), clamp(ceil(Int, maximum(cols)) + ROI_MARGIN, 1, sz[2]))
end

# find tag `id` by local search from `box`, expanding until found or the box is the whole frame.
# returns (corners in global [col,row], updated tight box) or (nothing, box) if never found.
function find_tag_roi(det, img, id, box, sz)
    r1, c1, r2, c2 = box
    while true
        tags = detect_locked(det, collect(@view img[r1:r2, c1:c2]))
        k = findfirst(t -> t.id == id, tags)
        if k !== nothing
            corners = SVector{2,Float64}[SVector(p[1] + c1 - 1, p[2] + r1 - 1) for p in tags[k].p]
            return corners, tag_box(corners, sz)
        end
        (r1 == 1 && c1 == 1 && r2 == sz[1] && c2 == sz[2]) && return nothing, box
        r1 = max(1, r1 - ROI_GROW); c1 = max(1, c1 - ROI_GROW)
        r2 = min(sz[1], r2 + ROI_GROW); c2 = min(sz[2], c2 + ROI_GROW)
    end
end

# detect all tags by per-tag local search, updating `boxes` in place; corners aligned to `ids`
# order, or `nothing` if any tag is not found anywhere in the frame. Sequential, because
# `detect_locked` serializes every detect anyway — one task per tag would only contend on the lock.
function detect_tags_roi!(dets, img, ids, boxes, sz)
    corners = Vector{Vector{SVector{2, Float64}}}(undef, length(ids))
    newboxes = similar(boxes)
    for k in eachindex(ids)
        tc, box = find_tag_roi(dets[k], img, ids[k], boxes[k], sz)
        isnothing(tc) && return nothing                       # a tag is lost: boxes stay untouched
        corners[k] = tc
        newboxes[k] = box
    end
    boxes .= newboxes                                         # commit only when every tag was found
    return corners
end

# Diagnostic scene for AprilTag mode: a top-down rectified video. Each frame is warped into a fixed
# cm canvas through that frame's own image→cm homography, so a correct rectification renders the
# ground plane stationary (the tags stop moving) while the beetle dot follows the target — letting
# the user judge both rectification quality and tracking at a glance. The canvas covers the
# reference tags' cm bounding box (plus a margin) at a fixed pixel size, with square pixels.
struct ApriltagScene
    m::Int
    xc::Float64                                   # canvas ↔ cm: centre (cm) …
    yc::Float64
    ppc::Float64                                  # … and pixels-per-cm
end

function ApriltagScene(ref)
    m = DIAGNOSTIC_SIZE
    cm = [apply_h(ref.M, p) for p in ref.corners]           # tag corners in ground cm
    xs = getindex.(cm, 1)
    ys = getindex.(cm, 2)
    extent = max(maximum(xs) - minimum(xs), maximum(ys) - minimum(ys))
    span = extent + 2 * 0.15 * extent                       # the tags' bounding box, plus a margin
    return ApriltagScene(m, (minimum(xs) + maximum(xs)) / 2, (minimum(ys) + maximum(ys)) / 2, m / span)
end

canvas_prototype(s::ApriltagScene) = Matrix{Gray{N0f8}}(undef, s.m, s.m)
update_ratio!(::ApriltagScene, _) = nothing

# canvas pixel (row i, col j) ↔ ground cm (x, y), square pixels centred on (xc, yc)
_canvas_to_cm(s::ApriltagScene, i, j) = SVector(s.xc + (j - s.m/2)/s.ppc, s.yc + (i - s.m/2)/s.ppc)
_cm_to_canvas(s::ApriltagScene, cm) = CartesianIndex(round(Int, (cm[2]-s.yc)*s.ppc + s.m/2),
                                                     round(Int, (cm[1]-s.xc)*s.ppc + s.m/2))

# Warp `frame` into the cm canvas via this frame's image→cm homography `H`. `beetle` is `missing` on
# frames without a full tag set, and `H` is `nothing` when there is no map at all — then every canvas
# pixel reads out of bounds and the frame comes out filled.
function (s::ApriltagScene)(frame, beetle, H)
    Hinv = isnothing(H) ? nothing : inv(H)
    # output canvas (i,j) → source image (row,col): canvas→cm→image (cm→image is inv(H))
    tf = idx -> begin
        isnothing(Hinv) && return SVector(-1.0, -1.0)           # no map → fill (out of bounds)
        c = _canvas_to_cm(s, idx[1], idx[2]); v = Hinv * SVector(c[1], c[2], 1.0)
        SVector(v[2]/v[3], v[1]/v[3])                           # (row, col) = (img_y, img_x)
    end
    # `convert` rather than a broadcast, for the reason given at RectifiedScene: `frame` is a stack
    # slice in the prefill loop and `vid.img` in the rolling one, both `Gray{N0f8}` already.
    wimg = warp(convert(AbstractArray{Gray{N0f8}}, frame), tf, (1:s.m, 1:s.m); fillvalue = zero(Gray{N0f8}))
    return wimg, ismissing(beetle) ? missing : _cm_to_canvas(s, beetle)
end

diagnose_apriltag(::Nothing, _, _, _) = Dont()
diagnose_apriltag(file::AbstractString, ref, darker_target, fps) =
    Diagnostic(file, darker_target, fps, ApriltagScene(ref);
               radius = max(2, DIAGNOSTIC_SIZE ÷ 60), font = DIAGNOSTIC_SIZE ÷ 16)

# Track the beetle across drone footage in a single pass, in the REFERENCE frame's coordinates: the
# background stack lazily warps every slice through that slice's own registration (a RegisteredWarp
# composed into the same index pipe as the scaling), so drone motion is removed at lookup time and
# the DoG tracker sees a static scene — a stable background model, and no per-frame guess
# compensation. Per frame: detect the tags (on the raw `vid.img`), fit the registration, roll the
# raw frame plus its registration into the stack, run the DoG detection in reference space, and map
# the result through the FIXED metric map `ref.M` to ground cm. Frames missing any tag yield
# `missing` — their true registration is unknown, so the slice borrows the nearest known one and the
# tracker holds its last reference-space position.
#
# The reference is established once, from the calibration's extrinsic frame, and shared here;
# `family` is the detector family it was built with; `ref_sz` is the reference frame's (rows, cols),
# which the run's own resolution may differ from. `dia` is an AprilTag `Diagnostic`/`Dont` created and
# closed by the caller, shared across a run's segments.
function track_apriltag(file, start, stop, target_width, start_location, window_size, darker_target,
                        native_fps, sample_fps, dia, ref::ReferenceFrame, family, ref_sz, initial_search_factor, scale, background_length)
    ids = ref.ids
    ntags = length(ids)
    video(file, native_fps, sample_fps, start, stop, scale) do vid
        dets = [set_detector!(AprilTagDetector(family)) for _ in 1:ntags]   # one per tag
        try
            canvas = round.(Int, vid.scale .* ref_sz)      # the reference viewport, tracker-scaled
            subtract = background_length != 0              # off ⇒ raw-slice detect, no protect/restore
            tr = Tracker(vid, darker_target, target_width, window_size, canvas, subtract)
            n_bkgd = n_background(vid, background_length)
            warp = RegisteredWarp(vid.scale, Vector{SMatrix{3, 3, Float64, 9}}(undef, n_bkgd))
            stack = get_stack(vid, tr.sz, tr.h, n_bkgd, warp)
            n = vid.nframes
            sz = size(vid.img)                             # raw frame size (row, col)
            # image→cm per prefill frame (dia + gating); length parameter as in Hinvs above
            Hs = Vector{Union{Nothing, SMatrix{3, 3, Float64, 9}}}(undef, n_bkgd)
            coords = Vector{Union{Missing, RowCol}}(undef, n)
            boxes = NTuple{4, Int}[]                       # per-tag ROI search boxes
            seeded = false
            seedR = SMatrix{3, 3, Float64}(I)              # the seed frame's registration (start_location crosses it)
            lastHinv = SMatrix{3, 3, Float64}(I)           # nearest known inv(registration), borrowed by tag-less slices

            # Fill the background stack: each frame enters raw, PLUS its registration in
            # `warp.Hinvs`, which is what places it in reference space. The run's `start` can be far
            # from the calibration's extrinsic frame, so the (stationary) tags may sit anywhere in
            # the first frame: locate them by a full-frame scan, NOT an ROI around their reference
            # positions. Subsequent frames then use per-tag local search seeded from each tag's last
            # box. Frames missing any tag borrow the nearest known registration (pre-seed slices are
            # backfilled with the seed's once it is found).
            for i in 1:n_bkgd
                next!(vid)
                populate_slice!(stack, i, vid)
                tc = seeded ? detect_tags_roi!(dets, vid.img, ids, boxes, sz) :
                              detect_tags(dets[1], vid.img, ids)             # whole-frame relocation
                if isnothing(tc)
                    Hs[i] = nothing
                    seeded && (warp.Hinvs[i] = lastHinv)   # pre-seed slices are backfilled below
                else
                    R = register(ref, reduce(vcat, tc))
                    lastHinv = inv(R)
                    warp.Hinvs[i] = lastHinv
                    Hs[i] = ref.M * R
                    if !seeded
                        boxes = [tag_box(c, sz) for c in tc]
                        seedR = R
                        for k in 1:i-1
                            warp.Hinvs[k] = lastHinv
                        end
                        seeded = true
                    end
                end
            end
            !seeded && error("no frame in the background window held all $ntags AprilTags")

            slice(k) = selectdim(parent(parent(stack)), 3, k)   # frame k's raw image (in the stack)

            # track the already-read background-window frames. Frames without a registration of
            # their own are reported `missing` and skipped (their borrowed alignment is good enough
            # for the background model, not for a measurement); the guess holds through them.
            level = Ref(0.0)
            guess = apriltag_guess(start_location, stack, vid, darker_target, target_width, initial_search_factor, subtract, seedR)
            for i in 1:n_bkgd
                H = Hs[i]
                if isnothing(H)
                    coords[i] = missing
                else
                    rc, guess = detect(guess, stack, i, tr, vid.scale, level)
                    coords[i] = img_to_cm(ref.M, rc)       # rc is reference px; ref.M is the fixed metric map
                end
                dia(slice(i), coords[i], H)
            end

            # rolling phase: read, register, roll into the stack, track
            for i in (n_bkgd + 1):n
                next!(vid)
                j = mod1(i, n_bkgd)
                tc = detect_tags_roi!(dets, vid.img, ids, boxes, sz)
                if isnothing(tc)
                    H = nothing                            # slice borrows lastHinv below
                else
                    R = register(ref, reduce(vcat, tc))
                    lastHinv = inv(R)
                    H = ref.M * R
                end
                if subtract
                    protect, keep = protect_target(stack, j, guess, tr.radii, canvas2raw(lastHinv, vid.scale), PROTECT_PAD)
                end
                populate_slice!(stack, j, vid)
                warp.Hinvs[j] = lastHinv
                if isnothing(H)
                    coords[i] = missing
                else
                    rc, guess = detect(guess, stack, j, tr, vid.scale, level)
                    coords[i] = img_to_cm(ref.M, rc)
                end
                dia(vid.img, coords[i], H)
                subtract && restore_background!(stack, j, protect, keep)
            end

            # labeled from the effective rate, as in track_one (see the Video constructor)
            return (range(start; step = 1 / vid.sample_fps, length = n), coords)
        finally
            foreach(freeDetector!, dets)
        end
    end
end
