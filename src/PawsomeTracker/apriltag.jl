# AprilTag-based tracking for drone footage: register out drone motion and rectify the beetle
# track into metric ground-plane coordinates (cm), in a single pass, using four coplanar tags as
# landmarks. Built in phases; this file currently holds PHASE 1 (the ground-plane geometry, pure
# and unit-tested). Detection, the tracking loop, diagnostics, ROI search and parallelism follow
# in later phases — the salvageable detection scratch is preserved, commented, at the bottom.
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
using AprilTags: AprilTagDetector, freeDetector!

# tag36h11 physical geometry: the black border is a 96 cm square. AprilTags reports each tag's four
# corners (`.p`, as [col, row]) in the order that maps to the tag-local unit square below; scaled
# by half the side length these are the canonical corner positions in cm.
const TAG_SIZE_CM = 96.0
const CANON = let h = TAG_SIZE_CM / 2
    SVector{2, Float64}[SVector(-h, h), SVector(h, h), SVector(h, -h), SVector(-h, -h)]
end

# apply a 3×3 homography to a 2D point (perspective divide)
apply_h(H, p) = (v = H * SVector(p[1], p[2], 1.0); SVector(v[1] / v[3], v[2] / v[3]))

# Normalized (Hartley) DLT homography fitting `src[i] → dst[i]` from ≥ 4 correspondences, returned
# as an `SMatrix{3,3}`. Normalization (centre + isotropic scale, per point set) is what keeps the
# solve well-conditioned when the pixel coordinates are large and off-origin, as tag corners are.
function homography_dlt(src, dst)
    n = length(src)
    norm_pts(pts) = (c = sum(pts) / n; s = sqrt(2) / (sum(p -> norm(p - c), pts) / n);
                     (SMatrix{3,3,Float64}(s, 0, 0, 0, s, 0, -s*c[1], -s*c[2], 1),
                      [SVector(s * (p[1] - c[1]), s * (p[2] - c[2])) for p in pts]))
    Ts, ns = norm_pts(src)
    Td, nd = norm_pts(dst)
    A = Matrix{Float64}(undef, 2n, 9)
    for i in 1:n
        x, y = ns[i]; xp, yp = nd[i]
        A[2i-1, :] .= (-x, -y, -1, 0, 0, 0, xp*x, xp*y, xp)
        A[2i,   :] .= (0, 0, 0, -x, -y, -1, yp*x, yp*y, yp)
    end
    h = svd(A).V[:, end]                          # null space → the homography (up to scale)
    Hn = SMatrix{3,3,Float64}(h[1], h[4], h[7], h[2], h[5], h[8], h[3], h[6], h[9])  # row-major
    H = inv(Td) * Hn * Ts                         # undo the normalization
    H / H[3, 3]
end

# Rigid Procrustes: place the canonical 96 cm square (no scaling — its size is known exactly) onto
# four measured cm points, giving the best-fit true square at that pose. This is how each tag's
# known metric geometry is imposed during the consensus fit.
function place_square(D)
    mc = sum(CANON) / 4; md = sum(D) / 4
    H = sum((D[i] - md) * (CANON[i] - mc)' for i in 1:4)      # 2×2 cross-covariance
    F = svd(H); R = F.U * F.Vt
    det(R) < 0 && (R = F.U * SMatrix{2,2,Float64}(1, 0, 0, -1) * F.Vt)   # reflection guard
    [R * (c - mc) + md for c in CANON]
end

# worst deviation (cm) of any tag edge from the true 96 cm, under an image→cm homography `M`
_worst_side(M, tag_corners) = maximum(abs(norm(apply_h(M, tc[i]) - apply_h(M, tc[mod1(i+1, 4)])) - TAG_SIZE_CM)
                                      for tc in tag_corners for i in 1:4)

# best-fit rigid transform (rotation + translation, no scale) mapping point set `A` onto `B`,
# returned as a function — used to pin the metric fit's global gauge each iteration.
function rigid_align(A, B)
    ma = sum(A) / length(A); mb = sum(B) / length(B)
    H = sum((B[i] - mb) * (A[i] - ma)' for i in eachindex(A))
    F = svd(H); R = F.U * F.Vt
    det(R) < 0 && (R = F.U * SMatrix{2,2,Float64}(1, 0, 0, -1) * F.Vt)
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
function fit_metric(tag_corners; maxiter = 1000, tol = 1e-9, fail = 5.0)
    flat = reduce(vcat, tag_corners)
    bestM = homography_dlt(collect(tag_corners[1]), CANON); beste = _worst_side(bestM, tag_corners)
    for boot in eachindex(tag_corners)
        M = homography_dlt(collect(tag_corners[boot]), CANON); e = _worst_side(M, tag_corners)
        for _ in 1:maxiter
            sq = [place_square(SVector{2,Float64}[apply_h(M, p) for p in tc]) for tc in tag_corners]
            T = rigid_align(sq[1], CANON)                     # pin gauge: tag 1 → canonical square
            G = reduce(vcat, [[T(g) for g in s] for s in sq])
            Mn = homography_dlt(flat, G); en = _worst_side(Mn, tag_corners)
            en < beste && (bestM = Mn; beste = en)
            converged = abs(e - en) < tol
            M = Mn; e = en
            converged && break
        end
    end
    beste > fail && error("AprilTag metric fit did not converge (worst square error $(round(beste, digits=2)) cm > $fail); tags may be non-coplanar or mis-detected")
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

# `register`: homography mapping the current frame's image to the reference image, from all 16
# corners (already aligned to `ref.ids` order by the caller). `ground_homography`: the full
# image→cm map for this frame, composing registration with the fixed metric map.
register(ref::ReferenceFrame, corners) = homography_dlt(corners, ref.corners)
ground_homography(ref::ReferenceFrame, corners) = ref.M * register(ref, corners)

# ============================================================================================
# PHASE 2 — detection and the single-pass tracking loop.
# ============================================================================================

# The AprilTag detector needs a plain Gray{N0f8}/UInt8 matrix (not the Gray{Float32} background
# stack), so detection always runs on the raw frame. Whole-frame detection for now — the ROI /
# local-search fast path is PHASE 4.
function set_detector!(det)
    det.nThreads = Threads.nthreads()
    det.quad_decimate = 1.0
    det.quad_sigma = 0.0
    det.refine_edges = 1
    det.decode_sharpening = 0.25
    return det
end

# Detect and return the 16 corners grouped per tag, aligned to `ids` order (each tag's `.p` corners
# as [col, row]); `nothing` if any expected id is absent. `SVector`-typed so the geometry consumes
# them directly.
function detect_tags(det, img, ids)
    tags = det(collect(img))
    byid = Dict(t.id => t for t in tags)
    all(haskey(byid, i) for i in ids) || return nothing
    [SVector{2,Float64}[SVector(p[1], p[2]) for p in byid[i].p] for i in ids]
end

# tag geometry is (x, y) = (col, row); the DoG tracker works in (row, col). These bridge the two.
img_to_cm(H, rc) = apply_h(H, SVector(rc[2], rc[1]))                       # (row,col) px → cm
cm_to_img(H, cm) = (xy = apply_h(inv(H), cm); (round(Int, xy[2]), round(Int, xy[1])))  # cm → (row,col) px

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
        tags = det(collect(@view img[r1:r2, c1:c2]))
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
# order, or `nothing` if any tag is not found anywhere in the frame.
function detect_tags_roi!(det, img, ids, boxes, sz)
    out = Vector{Vector{SVector{2,Float64}}}(undef, length(ids))
    for k in eachindex(ids)
        corners, box = find_tag_roi(det, img, ids[k], boxes[k], sz)
        isnothing(corners) && return nothing
        boxes[k] = box; out[k] = corners
    end
    return out
end

# Diagnostic for AprilTag mode: a top-down rectified video. Each frame is warped into a fixed cm
# canvas through that frame's own image→cm homography, so a correct rectification renders the ground
# plane stationary (the tags stop moving) while the beetle dot follows the target — letting the user
# judge both rectification quality and tracking at a glance. The canvas covers the reference tags'
# cm bounding box (plus a margin) at a fixed pixel size, with square pixels.
struct DiagnoseApriltag <: Diagnosis
    writer::VideoWriter
    m::Int
    xc::Float64; yc::Float64; ppc::Float64        # canvas ↔ cm: centre (cm) and pixels-per-cm
    color::Gray{N0f8}
    trace::CircularBuffer{CartesianIndex{2}}
    state::Ref{Int}
    skip::Int
    radius::Int

    function DiagnoseApriltag(file, ref, darker_target, fps)
        m = DIAGNOSTIC_SIZE
        cm = [apply_h(ref.M, p) for p in ref.corners]           # tag corners in ground cm
        xs = getindex.(cm, 1); ys = getindex.(cm, 2)
        margin = 0.15 * max(maximum(xs) - minimum(xs), maximum(ys) - minimum(ys))
        xc = (minimum(xs) + maximum(xs)) / 2; yc = (minimum(ys) + maximum(ys)) / 2
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
    if beetle !== missing
        ij = _cm_to_canvas(d, beetle); push!(d.trace, ij)
        draw!(wimg, CirclePointRadius(ij, d.radius; thickness = max(1, d.radius ÷ 2), fill = false), d.color)
        draw!(wimg, Path(d.trace), d.color)
    end
    write(d.writer, parent(wimg))
    return nothing
end
diagnose_apriltag(::Nothing, _, _, _) = Dont()
diagnose_apriltag(file::AbstractString, ref, darker_target, fps) = DiagnoseApriltag(file, ref, darker_target, fps)
(::Dont)(_, _, _) = nothing                                     # 3-arg no-op for the apriltag callback

# Track the beetle across drone footage in a single pass: per frame, detect the tags, register the
# frame to the reference (removing drone motion), motion-compensate the tracker's guess, run the DoG
# detection, and report the beetle in metric ground coordinates (cm). Frames missing any tag yield
# `missing` (no registration possible) and the tracker holds its last position. The reference frame
# is the first frame in which all `ntags` tags are seen. Reuses the Tracker / background-stack / DoG
# machinery; detection is on the raw frame, tracking on the stack.
function track_apriltag(file, start, stop, target_width, start_location, window_size, darker_target,
                        fps, diagnostic_file, ntags, initial_search_factor, white_point, scale)
    video(file, fps, start, stop, scale) do vid
        det = AprilTagDetector(); set_detector!(det)
        try
            tr = Tracker(vid, darker_target, target_width, window_size)
            stack = get_stack(vid, tr.sz, tr.h); n_bkgd = size(stack, 3); n = vid.nframes
            sz = size(vid.img)                                            # raw frame size (row, col)
            Hs = Vector{Union{Nothing, SMatrix{3,3,Float64}}}(undef, n)    # per-frame image→cm map
            coords = Vector{Union{Missing, RowCol}}(undef, n)
            ref = nothing; ids = Int[]; boxes = NTuple{4,Int}[]           # per-tag ROI search boxes

            # fill the background stack, detecting tags and establishing the reference as we go. Until
            # the reference is set the tag ids are unknown, so detection is whole-frame; afterwards it
            # is per-tag local search seeded from each tag's last box (PHASE 4).
            for i in 1:n_bkgd
                next!(vid); populate_slice!(stack, i, vid)
                if ref === nothing
                    tags = det(collect(vid.img))
                    if length(tags) ≥ ntags
                        ids = sort(getfield.(tags, :id))[1:ntags]
                        reftc = detect_tags(det, vid.img, ids)
                        ref = ReferenceFrame(ids, reftc)
                        boxes = [tag_box(c, sz) for c in reftc]
                    end
                    Hs[i] = ref === nothing ? nothing : ref.M              # reference frame: H = M
                else
                    tc = detect_tags_roi!(det, vid.img, ids, boxes, sz)
                    Hs[i] = isnothing(tc) ? nothing : ground_homography(ref, reduce(vcat, tc))
                end
            end
            isnothing(ref) && error("no frame in the background window held all $ntags AprilTags")

            dia = diagnose_apriltag(diagnostic_file, ref, darker_target, fps)
            slice(k) = selectdim(parent(parent(stack)), 3, k)              # frame k's image (in the stack)
            try
                # track the already-read background-window frames (images are the stack slices)
                level = Ref(0.0)
                guess = get_guess(start_location, stack, vid, darker_target, target_width, initial_search_factor)
                prev = missing
                for i in 1:n_bkgd
                    H = Hs[i]
                    if isnothing(H)
                        coords[i] = missing
                    else
                        prev !== missing && (guess = cm_to_img(H, prev))
                        rc, guess = detect(guess, stack, i, tr.h, tr.img, tr.radii, tr.buff, tr.kernel, tr.sz, vid.scale, tr.bkgd_reduce, level)
                        coords[i] = img_to_cm(H, rc); prev = coords[i]
                    end
                    dia(slice(i), coords[i], H)
                end

                # rolling phase: read, detect, track
                for i in (n_bkgd + 1):n
                    next!(vid); j = mod1(i, n_bkgd)
                    tc = detect_tags_roi!(det, vid.img, ids, boxes, sz)
                    H = isnothing(tc) ? nothing : ground_homography(ref, reduce(vcat, tc))
                    isnothing(H) || prev === missing || (guess = cm_to_img(H, prev))
                    protect, keep = protect_target(stack, j, guess, tr.radii, vid.scale)
                    populate_slice!(stack, j, vid)
                    if isnothing(H)
                        coords[i] = missing
                    else
                        rc, guess = detect(guess, stack, j, tr.h, tr.img, tr.radii, tr.buff, tr.kernel, tr.sz, vid.scale, tr.bkgd_reduce, level)
                        coords[i] = img_to_cm(H, rc); prev = coords[i]
                    end
                    dia(vid.img, coords[i], H)
                    restore_background!(stack, j, protect, keep)
                end
            finally
                close(dia)
            end
            return (range(start, stop, n), coords)
        finally
            freeDetector!(det)
        end
    end
end
