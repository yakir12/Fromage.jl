# AprilTag-based tracking for drone footage: register out drone motion and rectify the beetle
# track into metric ground-plane coordinates (cm), in a single pass, using four coplanar tags as
# landmarks. Built in phases, all present in this file: PHASE 1 the ground-plane geometry (pure
# and unit-tested), PHASE 2 detection and the tracking loop, PHASE 4 the ROI local search.
# Registration is folded into the background stack's lazy index pipe (RegisteredWarp), so the
# tracker works in the shared reference frame — a static scene — rather than native image space.
#
# Geometry, verified against a real drone frame (1080×1920, four tag36h11 tags):
#   * A homography from all 16 tag corners registers frames robustly; a single tag's homography
#     leaves 3.5–13.4 cm of skew on distant tags (error grows with distance from the tag), so
#     every fit uses all corners.
#   * The metric map (image → cm) is fit from all four tags jointly, each contributing its known
#     96 cm square; consensus drives the worst square error to < 1 cm (vs. 13 cm single-tag).
#   * Our normalized-DLT homography is both more accurate (Float64 vs OpenCV's Float32 marshalling)
#     and faster (~28 µs vs ~41 µs) than OpenCV.findHomography, so no OpenCV dependency is needed.

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
const APRIL_FAMILIES = Dict("tag36h11" => AprilTags.tag36h11, "tag25h9" => AprilTags.tag25h9,
                            "tag16h5" => AprilTags.tag16h5)
const CELLS_ACROSS = Dict("tag36h11" => 8, "tag25h9" => 7, "tag16h5" => 6)

# The canonical tag corners in real-world units, in the detector's `.p` order, for a tag of
# `family` whose single cell measures `cell` units. `CANON`/`TAG_SIZE_CM` are the default gauge —
# tag36h11 at 12 cm/cell ⇒ a 96 cm black-border square — on which the geometry unit tests are built.
function canon_square(family, cell)
    h = CELLS_ACROSS[family] * cell / 2
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

# Rigid Procrustes: place the canonical square `canon` (no scaling — its size is known exactly) onto
# four measured cm points, giving the best-fit true square at that pose. This is how each tag's
# known metric geometry is imposed during the consensus fit.
function place_square(D, canon = CANON)
    mc = sum(canon) / 4
    md = sum(D) / 4
    H = sum((D[i] - md) * (canon[i] - mc)' for i in 1:4)      # 2×2 cross-covariance
    F = svd(H)
    R = F.U * F.Vt
    if det(R) < 0                                             # reflection guard
        R = F.U * SMatrix{2, 2, Float64}(1, 0, 0, -1) * F.Vt
    end
    [R * (c - mc) + md for c in canon]
end

# worst deviation (real units) of any tag edge from the true side length `side`, under an
# image→cm homography `M`
_worst_side(M, tag_corners, side = TAG_SIZE_CM) =
    maximum(abs(norm(apply_h(M, tc[i]) - apply_h(M, tc[mod1(i+1, 4)])) - side)
            for tc in tag_corners for i in 1:4)

# best-fit rigid transform (rotation + translation, no scale) mapping point set `A` onto `B`,
# returned as a function — used to pin the metric fit's global gauge each iteration.
function rigid_align(A, B)
    ma = sum(A) / length(A)
    mb = sum(B) / length(B)
    H = sum((B[i] - mb) * (A[i] - ma)' for i in eachindex(A))
    F = svd(H)
    R = F.U * F.Vt
    if det(R) < 0                                             # reflection guard
        R = F.U * SMatrix{2, 2, Float64}(1, 0, 0, -1) * F.Vt
    end
    p -> R * (p - ma) + mb
end

# Fit the metric map `M : image → ground cm` from all tags jointly. Bootstrap from one tag's
# corners, then alternate: place a true 96 cm square on each tag's current cm estimate (Procrustes),
# pin the global gauge by rigidly mapping tag 1's square back onto the canonical square, and refit
# `M` from all 16 corners to those pinned squares (DLT). The gauge pin is essential — without it the
# iteration's cm frame drifts in scale/pose and diverges under strong perspective.
#
# The gauge-pinned iteration still has convergence basins: which bootstrap tag lands in the good
# basin is sensitive to sub-pixel corner noise (a 0.1 px difference flipped a real frame from 0.5 cm
# to 35 cm), so we try EVERY tag as the bootstrap and keep the globally best result. On real footage
# at least one bootstrap reaches sub-cm; `fail` throws if none does (non-coplanar / mis-detected
# tags). Fit once per reference frame — the whole thing is a one-time few ms, not a per-frame cost.
function fit_metric(tag_corners; canon = CANON, maxiter = 1000, tol = 1e-9, fail = 5.0)
    side = norm(canon[1] - canon[2])
    flat = reduce(vcat, tag_corners)
    bestM = homography_dlt(collect(tag_corners[1]), canon)
    beste = _worst_side(bestM, tag_corners, side)
    for boot in eachindex(tag_corners)
        M = homography_dlt(collect(tag_corners[boot]), canon)
        e = _worst_side(M, tag_corners, side)
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
    beste > fail && error("AprilTag metric fit did not converge (worst square error $(round(beste, digits=2)) > $fail; in the calibration's real units); tags may be non-coplanar or mis-detected")
    return bestM
end

# The reference frame: the tag ids (their order fixes the corner alignment used every frame), the
# 16 reference-image corners, and the metric map `M : reference image → ground cm`.
struct ReferenceFrame
    ids::Vector{Int}
    corners::Vector{SVector{2, Float64}}          # flat 16, tag-major in `ids` order
    M::SMatrix{3, 3, Float64}
end

function ReferenceFrame(ids::AbstractVector{<:Integer}, tag_corners; kw...)
    ReferenceFrame(collect(Int, ids), reduce(vcat, tag_corners), fit_metric(tag_corners; kw...))
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
    fam = get(APRIL_FAMILIES, family, nothing)
    isnothing(fam) && error("unknown AprilTag family \"$family\" (supported: $(join(sort(collect(keys(APRIL_FAMILIES))), ", ")))")
    return fam
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
# of `family`, take the `ntags` lowest ids, and fit the metric map from their known cell geometry
# (`fit_metric` throws if the tags are not coplanar / were mis-detected).
function reference_frame(file, extrinsic, ntags, family, checker_size)
    # Serialize the WHOLE read + detect. Two separate hazards, both under the verification /
    # rectification-building `tmap` at high thread counts on a cold network share: the one-shot VideoIO
    # read (open+seek+read) races and returns garbled/wrong frames, and the AprilTag detector is not
    # reentrant. Reference building is one-time setup over a handful of calibs, so serializing it costs
    # essentially nothing. (Per-run tracking keeps concurrent decode; only its detection is serialized.)
    lock(APRILTAG_LOCK) do
        img = read_frame_at(file, extrinsic)
        det = set_detector!(AprilTagDetector(april_family(family)))
        try
            tags = det(collect(img))                # already holding APRILTAG_LOCK
            length(tags) ≥ ntags || error("only $(length(tags)) of $ntags AprilTags detected at the extrinsic frame")
            ids = sort([t.id for t in tags])[1:ntags]
            tc = detect_tags(det, img, ids)         # re-enters the lock (re-entrant), fine
            isnothing(tc) && error("could not read all $ntags AprilTag corners at the extrinsic frame")
            ReferenceFrame(ids, tc; canon = canon_square(family, checker_size))
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
function apriltag_image2real(M, center, north, width, height)
    c = ismissing(center) ? SVector{2, Float64}(width / 2, height / 2) : SVector{2, Float64}(center[1], center[2])
    n = ismissing(north) ? missing : SVector{2, Float64}(north[1], north[2])
    # `f` mirrors a video image2real: reference pixel (col, row) → real (y, x). Feeding it and the
    # gauge points to the shared centre/north helpers pins the SAME north convention as the video path.
    f = p -> (cm = apply_h(M, SVector(Float64(p[1]), Float64(p[2]))); SVector(cm[2], cm[1]))
    centering, northing = i2r_centering_northing(f, c, n)
    gauge = northing ∘ centering
    return cm -> gauge(SVector(Float64(cm[2]), Float64(cm[1])))     # raw cm (x, y) → gauged real (y, x)
end

# Build the AprilTag rectification from a verified `type = apriltag` calibs row.
function ApriltagRectification(file, extrinsic, ntags, family, checker_size, center, north, width, height)
    ref = reference_frame(file, extrinsic, ntags, family, checker_size)
    i2r = apriltag_image2real(ref.M, center, north, width, height)
    return ApriltagRectification(ref, april_family(family), i2r, reference_ratio(ref), width, height)
end

# ---- verification hooks (used by VerifyRectifications) ---------------------------------------
# The families the `family` column may name, and a cheap validity predicate for it.
const APRIL_FAMILY_NAMES = sort(collect(keys(APRIL_FAMILIES)))
valid_apriltag_family(family) = haskey(APRIL_FAMILIES, family)

# Does the extrinsic frame support a shared reference? Returns `nothing` on success or an issue
# string (unreadable frame, too few tags, non-coplanar / mis-detected tags) — never throws, so it
# composes with the gateway's other checks.
function apriltag_extrinsic_issue(file, extrinsic, ntags, family, checker_size)
    try
        reference_frame(file, extrinsic, ntags, family, checker_size)
        return nothing
    catch e
        return sprint(showerror, e)
    end
end

# `register`: homography mapping the current frame's image to the reference image, from all 16
# corners (already aligned to `ref.ids` order by the caller). `ground_homography`: the full
# image→cm map for this frame, composing registration with the fixed metric map.
register(ref::ReferenceFrame, corners) = homography_dlt(corners, ref.corners)
ground_homography(ref::ReferenceFrame, corners) = ref.M * register(ref, corners)

# The lazy registration warp: the background stack's index transform, composing each slice's
# registration with the tracker's inverse scaling, so every slice is sampled in the SHARED
# REFERENCE frame's coordinates. Drone motion is thereby removed at lookup time — the per-pixel
# max/min background model sees a static scene — at the cost of one homography apply per lookup.
# `Hinvs[k]` maps reference (x, y) px → frame-k (x, y) px (i.e. `inv(register(...))`) and is
# mutated in place as the rolling window replaces slices; the WarpedView holds this same vector,
# so updates are visible immediately. Coordinate bridge: the stack works in scaled (row, col)
# ("canvas"), the homographies in (x, y) = (col, row) stored px — hence the flips.
struct RegisteredWarp <: Transformation
    scale::Float64
    # NB the length parameter: `SMatrix{3, 3, Float64}` (abstract) would box every per-lookup
    # load and cost two orders of magnitude in detect's background reduce
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
# PHASE 2 — detection and the single-pass tracking loop.
# ============================================================================================

# The AprilTag detector needs a plain Gray{N0f8}/UInt8 matrix (not the Gray{Float32} background
# stack), so detection always runs on the raw frame. Whole-frame detection for now — the ROI /
# local-search fast path is PHASE 4.
function set_detector!(det; nthreads = 1)
    det.nThreads = nthreads
    det.quad_decimate = 1.0
    det.quad_sigma = 0.0
    det.refine_edges = 1
    det.decode_sharpening = 0.25
    return det
end

# `apriltag_detector_detect` (the C detector) is NOT reentrant: it has global/static state that
# concurrent calls corrupt — even distinct, per-thread detectors on distinct frames race (verified
# three ways), and under enough pressure it segfaults. So EVERY detection call goes through this,
# which serializes them process-wide via APRILTAG_LOCK. Reads/decode stay concurrent; only the
# (comparatively cheap) detect is serial.
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

# ---- PHASE 4: local ROI search ----------------------------------------------------------------
# AprilTag detection cost scales with pixels, so after the reference frame each tag is searched in a
# small box around where it was last seen instead of over the whole 1080×1920 frame. Detecting on a
# crop reproduces the full-frame corners to < 0.1 px (verified), so this is a pure speedup. The box
# grows and re-searches until the tag is found or it spans the whole frame — a graceful fallback to
# full-frame detection when the drone jumps, never worse than it.
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
# order, or `nothing` if any tag is not found anywhere in the frame. Detection is SEQUENTIAL: the
# AprilTag C detector is not reentrant (see detect_locked), so every detect is serialized process-
# wide anyway — spawning one task per tag would only contend on that lock, for no gain.
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

# Diagnostic for AprilTag mode: a top-down rectified video. Each frame is warped into a fixed cm
# canvas through that frame's own image→cm homography, so a correct rectification renders the ground
# plane stationary (the tags stop moving) while the beetle dot follows the target — letting the user
# judge both rectification quality and tracking at a glance. The canvas covers the reference tags'
# cm bounding box (plus a margin) at a fixed pixel size, with square pixels.
struct DiagnoseApriltag <: Diagnosis
    writer::VideoWriter
    m::Int
    xc::Float64                                   # canvas ↔ cm: centre (cm) …
    yc::Float64
    ppc::Float64                                  # … and pixels-per-cm
    color::Gray{N0f8}
    trace::CircularBuffer{CartesianIndex{2}}
    state::Ref{Int}
    skip::Int
    radius::Int

    function DiagnoseApriltag(file::AbstractString, ref, darker_target, fps)
        m = DIAGNOSTIC_SIZE
        cm = [apply_h(ref.M, p) for p in ref.corners]           # tag corners in ground cm
        xs = getindex.(cm, 1)
        ys = getindex.(cm, 2)
        margin = 0.15 * max(maximum(xs) - minimum(xs), maximum(ys) - minimum(ys))
        xc = (minimum(xs) + maximum(xs)) / 2
        yc = (minimum(ys) + maximum(ys)) / 2
        span = max(maximum(xs) - minimum(xs), maximum(ys) - minimum(ys)) + 2margin
        ppc = m / span
        skip = diagnostic_stride(fps)
        buffer = Matrix{Gray{N0f8}}(undef, m, m)
        writer = open_video_out(file, buffer; framerate = diagnostic_framerate(fps, skip),
            encoder_private_options = DIAGNOSTIC_ENCODER)
        new(writer, m, xc, yc, ppc, darker_target ? Gray{N0f8}(1) : Gray{N0f8}(0),
            CircularBuffer{CartesianIndex{2}}(TRACE_BUFFER_SIZE), Ref(0), skip, max(2, m ÷ 60))
    end
end

# canvas pixel (row i, col j) ↔ ground cm (x, y), square pixels centred on (xc, yc)
_canvas_to_cm(d::DiagnoseApriltag, i, j) = SVector(d.xc + (j - d.m/2)/d.ppc, d.yc + (i - d.m/2)/d.ppc)
_cm_to_canvas(d::DiagnoseApriltag, cm) = CartesianIndex(round(Int, (cm[2]-d.yc)*d.ppc + d.m/2),
                                                        round(Int, (cm[1]-d.xc)*d.ppc + d.m/2))

# per-frame: warp `frame` into the cm canvas via this frame's image→cm homography `H`, draw the
# beetle (in cm) and its trace. `beetle` is `missing` on frames without a full tag set.
function (d::DiagnoseApriltag)(frame, beetle, H)
    d.state[] += 1
    rem(d.state[], d.skip) == 0 || return nothing
    Hinv = isnothing(H) ? nothing : inv(H)
    # output canvas (i,j) → source image (row,col): canvas→cm→image (cm→image is inv(H))
    tf = idx -> begin
        isnothing(Hinv) && return SVector(-1.0, -1.0)           # no map → fill (out of bounds)
        c = _canvas_to_cm(d, idx[1], idx[2]); v = Hinv * SVector(c[1], c[2], 1.0)
        SVector(v[2]/v[3], v[1]/v[3])                           # (row, col) = (img_y, img_x)
    end
    wimg = warp(Gray{N0f8}.(frame), tf, (1:d.m, 1:d.m); fillvalue = zero(Gray{N0f8}))
    if !ismissing(beetle)
        ij = _cm_to_canvas(d, beetle)
        push!(d.trace, ij)
        draw!(wimg, CirclePointRadius(ij, d.radius; thickness = max(1, d.radius ÷ 2), fill = false), d.color)
        draw!(wimg, Path(d.trace), d.color)
    end
    write(d.writer, parent(wimg))
    return nothing
end
diagnose_apriltag(::Nothing, _, _, _) = Dont()
diagnose_apriltag(file::AbstractString, ref, darker_target, fps) = DiagnoseApriltag(file, ref, darker_target, fps)
(::Dont)(_, _, _) = nothing                                     # 3-arg no-op for the apriltag callback

# Track the beetle across drone footage in a single pass, in the REFERENCE frame's coordinates:
# the background stack lazily warps every slice through that slice's own registration (a
# RegisteredWarp composed into the same index pipe as the scaling), so drone motion is removed at
# lookup time and the DoG tracker sees a static scene — a stable background model, and no
# per-frame guess compensation (the guess simply persists, as in the plain tracker). Per frame:
# detect the tags (on the raw `vid.img`), fit the registration, roll the raw frame plus its
# registration into the stack, run the DoG detection in reference space, and map the result
# through the FIXED metric map `ref.M` to ground cm. Frames missing any tag yield `missing`
# (their true registration is unknown; the slice borrows the nearest known one — misaligned only
# by that brief unknown drone motion, where the old native-space stack was misaligned by ALL
# drone motion) and the tracker holds its last reference-space position. The reference is
# established once, from the calibration's extrinsic frame (the tags are stationary across every
# run), and shared here; `family` is the detector family it was built with; `ref_sz` is the
# reference frame's (rows, cols) — the run may have a different resolution. `dia` is a
# `DiagnoseApriltag`/`Dont` created (and closed) by the caller — shared across a run's segments.
function track_apriltag(file, start, stop, target_width, start_location, window_size, darker_target,
                        fps, dia, ref::ReferenceFrame, family, ref_sz, initial_search_factor, white_point, scale, background_length)
    ids = ref.ids
    ntags = length(ids)
    video(file, fps, start, stop, scale) do vid
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
            Hs = Vector{Union{Nothing, SMatrix{3, 3, Float64}}}(undef, n_bkgd)  # image→cm per prefill frame (dia + gating)
            coords = Vector{Union{Missing, RowCol}}(undef, n)
            boxes = NTuple{4, Int}[]                       # per-tag ROI search boxes
            seeded = false
            seedR = SMatrix{3, 3, Float64}(I)              # the seed frame's registration (start_location crosses it)
            lastHinv = SMatrix{3, 3, Float64}(I)           # nearest known inv(registration), borrowed by tag-less slices

            # fill the background stack: each frame enters raw, PLUS its registration in
            # `warp.Hinvs`, which is what places it in reference space. The run's `start` can be far
            # from the calibration's extrinsic frame, so the (stationary) tags may sit anywhere in
            # the first frame: locate them by a full-frame scan, NOT an ROI around their reference
            # positions. Once found, subsequent frames use per-tag local search seeded from each
            # tag's last box — a graceful fall back to full-frame when the drone jumps. Frames
            # missing any tag borrow the nearest known registration (pre-seed slices are backfilled
            # with the seed's once it is found).
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
                    rc, guess = detect(guess, stack, i, tr.h, tr.img, tr.radii, tr.buff, tr.kernel, tr.sz, vid.scale, tr.bkgd_reduce, level)
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
                    rc, guess = detect(guess, stack, j, tr.h, tr.img, tr.radii, tr.buff, tr.kernel, tr.sz, vid.scale, tr.bkgd_reduce, level)
                    coords[i] = img_to_cm(ref.M, rc)
                end
                dia(vid.img, coords[i], H)
                subtract && restore_background!(stack, j, protect, keep)
            end

            return (range(start, stop, n), coords)
        finally
            foreach(freeDetector!, dets)
        end
    end
end
