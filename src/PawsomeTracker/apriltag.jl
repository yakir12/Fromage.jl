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

using StaticArrays: SVector, SMatrix, MVector
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
# iteration's cm frame drifts in scale/pose and diverges under strong perspective; with it the fit
# converges to sub-cm worst-square error on real footage (and machine precision on clean synthetic).
# `keep-best` returns the best `M` seen, and `fail` guards against a non-coplanar / mis-detected set
# by throwing rather than returning a silently wrong map. Fit once per reference frame — the
# iteration cost is a one-time few ms, not per frame.
function fit_metric(tag_corners; maxiter = 1000, tol = 1e-9, fail = 5.0)
    flat = reduce(vcat, tag_corners)
    M = homography_dlt(collect(tag_corners[1]), CANON)        # bootstrap image→cm from one tag
    e = _worst_side(M, tag_corners); bestM = M; beste = e
    for _ in 1:maxiter
        sq = [place_square(SVector{2,Float64}[apply_h(M, p) for p in tc]) for tc in tag_corners]
        T = rigid_align(sq[1], CANON)                         # pin gauge: tag 1 → canonical square
        G = reduce(vcat, [[T(g) for g in s] for s in sq])
        Mn = homography_dlt(flat, G); en = _worst_side(Mn, tag_corners)
        en < beste && (bestM = Mn; beste = en)
        converged = abs(e - en) < tol
        M = Mn; e = en
        converged && break
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
# PHASE 2+ reference — detection, ROI search and the tracking-loop wiring, to integrate next.
# Preserved from the original scratch; not active (needs AprilTags/VideoIO), kept for reuse.
# ============================================================================================
#
# const widen_radius = 50
# const SV = SVector{2, Float64}
#
# function set_detector!(detector)
#     detector.nThreads = Threads.nthreads()
#     detector.quad_decimate = 1.0
#     detector.quad_sigma = 0.0
#     detector.refine_edges = 1
#     detector.decode_sharpening = 0.25
#     return detector
# end
#
# # Per-tag ROI detector with an expanding search rectangle (PHASE 4: local search / reacquisition).
# struct DetectoRect
#     sz::NTuple{2, Int}
#     detector::AprilTagDetector
#     rect::MVector{4, Int}
#     min_radius::Float64
#     function DetectoRect(sz)
#         detector = AprilTagDetector(); set_detector!(detector)
#         new(sz, detector, MVector(1, 1, sz...), 10)
#     end
# end
# Base.close(d::DetectoRect) = freeDetector!(d.detector)
#
# function (d::DetectoRect)(buff)
#     r1, c1, r2, c2 = d.rect
#     tags = d.detector(buff[r1:r2, c1:c2])
#     if length(tags) ≠ 1                        # not found → widen the ROI
#         d.rect[1:2] .= max.(1, d.rect[1:2] .- widen_radius)
#         d.rect[3:4] .= min.(d.sz, d.rect[3:4] .+ widen_radius)
#         return nothing
#     else
#         t = only(tags); c = SV(reverse(t.H[1:2, 3])) + SV(r1, c1)   # tag centre → global (row,col)
#         d.rect[1:2] .= max.(1, round.(Int, c .- d.min_radius))
#         d.rect[3:4] .= min.(d.sz, round.(Int, c .+ d.min_radius))
#         return t
#     end
# end
#
# # Original per-frame homography chain (PHASE 2): frame→reference (h) then reference→ground (H, from
# # a tag's own homography), scaled to cm. Superseded by fit_metric + ground_homography above, kept
# # for reference:
# #   trans = LinearMap(SDiagonal(96/2, 96/2)) ∘ pop ∘ LinearMap(H) ∘ LinearMap(h) ∘ push1 ∘ RowCol
