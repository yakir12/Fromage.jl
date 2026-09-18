# The simulation's own dot detector (#289), independent of Fromage's tracker, and the analytic truth
# it is checked against. Ported from `detect_dots` in `prototype/baseline-rig:prototype/baseline_rig.jl`
# and `area_centroid` in `research/supersampling:prototype/supersampling/ss_detail.jl`.

using StaticArrays: SVector

"The grey level the arena renders to: the dot detector's background (#283)."
const BACKGROUND = round(UInt8, 255 * reflectance(ARENA))

# how far a dot's box reaches past its dark pixels, px: past every pixel the dot's edge can touch
const DOT_PAD = 3

"""
    detect_dots(img::AbstractMatrix{UInt8}) -> Vector{SVector{2, Float64}}

The sub-pixel centroids, 0-based stored `(row, col)`, of the dark blobs in `img` that sit alone on
the arena, in no particular order.

A blob is a 4-connected set of pixels darker than half the background. It is a dot only when the
border of its bounding box, padded by `DOT_PAD` px, is entirely arena ([`BACKGROUND`](@ref)) and
lies inside the frame: that rejects the board's black squares, which touch each other and its
margin, and anything on the floor or at the frame's edge. The centroid weighs every pixel of the
padded box by how much darker than the arena it is, so a pixel the dot's edge crosses counts by
its share. The background is the arena's grey level, never one estimated from the whole frame:
on a frame where the arena is a minority, that estimate lands on something else (#283).
"""
function detect_dots(img::AbstractMatrix{UInt8})
    dark = img .< BACKGROUND ÷ 2
    seen = falses(size(img))
    found = SVector{2, Float64}[]
    stack = CartesianIndex{2}[]
    blob = CartesianIndex{2}[]
    steps = (CartesianIndex(1, 0), CartesianIndex(-1, 0), CartesianIndex(0, 1), CartesianIndex(0, -1))
    for I in CartesianIndices(img)
        (dark[I] && !seen[I]) || continue
        empty!(blob)
        push!(stack, I)
        seen[I] = true
        while !isempty(stack)
            J = pop!(stack)
            push!(blob, J)
            for s in steps
                K = J + s
                checkbounds(Bool, img, K) && dark[K] && !seen[K] && (seen[K] = true; push!(stack, K))
            end
        end
        lo, hi = minimum(blob) - CartesianIndex(DOT_PAD, DOT_PAD), maximum(blob) + CartesianIndex(DOT_PAD, DOT_PAD)
        checkbounds(Bool, img, lo) && checkbounds(Bool, img, hi) || continue
        box = lo:hi
        on_arena = all(img[K] == BACKGROUND for K in box if K[1] in (lo[1], hi[1]) || K[2] in (lo[2], hi[2]))
        on_arena || continue
        w = r = c = 0.0
        for K in box
            wk = Float64(BACKGROUND) - img[K]
            w += wk
            r += wk * (K[1] - 1)
            c += wk * (K[2] - 1)
        end
        push!(found, SVector(r / w, c / w))
    end
    return found
end

"""
    area_centroid(cam::Camera, c; n = 20_000) -> SVector{2, Float64}

The area centroid, 0-based stored `(row, col)`, of the image of the dot centred at ground point `c`
(world `(X, Y)`, m): the centroid of the polygon its rim projects to, `n` vertices around. It is the
truth for [`detect_dots`](@ref), not the projection of the dot's centre, which perspective puts
0.04 px away at the baseline rig (#292).
"""
function area_centroid(cam::Camera, c; n = 20_000)
    rim = [project(cam, SVector(c[1] + DOT_RADIUS * cos(θ), c[2] + DOT_RADIUS * sin(θ), 0.0)) for θ in range(0, 2π, n + 1)[1:n]]
    any(isnothing, rim) && throw(ArgumentError("the dot at $c does not project whole"))
    A = r = col = 0.0
    for (i, p) in enumerate(rim)
        q = rim[mod1(i + 1, n)]
        cr = p[1] * q[2] - q[1] * p[2]
        A += cr
        r += (p[1] + q[1]) * cr
        col += (p[2] + q[2]) * cr
    end
    return SVector(r / 3A, col / 3A)
end
