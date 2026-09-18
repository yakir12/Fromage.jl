# Which grid ordering does findChessboardCorners (via Fromage's _detect_corners) hand back, and with
# which handedness relative to the world? Render the flat board (ray cast, 3x3 supersampling) and look.
using Fromage, LinearAlgebra, Printf
using StaticArrays: SVector
const R = Fromage.Rectifications

const F = 900.0
const CX, CY = 960.0 + 17.3, 540.0 - 11.7
const CW = 0.04
scales(sar) = sar >= 1 ? (1.0, 1 / sar) : (sar, 1.0)

function camera(α)
    Cpos = SVector(1.5cos(α), 1.5sin(α), 1.5)
    fwd = normalize(-Cpos)
    right = normalize(cross(fwd, SVector(0.0, 0.0, 1.0)))
    down = cross(fwd, right)
    return (; Cpos, fwd, right, down)
end
function backproject(cam, row, col, sar)
    sy, sx = scales(sar)
    x, y = col / sx, row / sy
    d = cam.right * (x - CX) / F + cam.down * (y - CY) / F + cam.fwd
    t = -cam.Cpos[3] / d[3]
    P = cam.Cpos + t * d
    return SVector(P[1], P[2])
end

# board: 11 x 8 squares of CW, long side along world direction `u` (unit 2D), centre at origin,
# one-square white margin; `parity` picks which squares are black
function reflectance(P, u, parity)
    v = SVector(-u[2], u[1])
    a, b = dot(P, u) / CW, dot(P, v) / CW                        # along long / short side, in squares
    (abs(a) > 5.5 + 1 || abs(b) > 4 + 1) && return 0.5           # floor (grey)
    (abs(a) > 5.5 || abs(b) > 4) && return 1.0                   # margin
    p, q = floor(Int, a + 5.5), floor(Int, b + 4)
    return isodd(p + q + parity) ? 0.0 : 1.0
end

function render(cam, u, parity, sar)
    sy, sx = scales(sar)
    h, w = round(Int, 1080sy), round(Int, 1920sx)
    img = Matrix{UInt8}(undef, h, w)
    ss = 3
    Threads.@threads for c in 1:w
        for r in 1:h
            acc = 0.0
            for i in 1:ss, j in 1:ss
                # pixel (r, c) covers stored [r-1, r] x [c-1, c] in OpenCV's continuous coords shifted by 0.5
                acc += reflectance(backproject(cam, r - 1 + (i - 0.5) / ss - 0.5, c - 1 + (j - 0.5) / ss - 0.5, sar), u, parity)
            end
            img[r, c] = round(UInt8, 255 * acc / ss^2)
        end
    end
    return img
end

println("n_corners  α(cam azimuth)  board long axis  parity  sar | e_i (world)   e_j (world)   detQ  origin corner (world)")
for sar in (1.0, 2.0, 0.5), α in (0.0, π / 2, π, 3π / 4), ulong in (SVector(0.0, 1.0), SVector(1.0, 0.0), normalize(SVector(1.0, 1.0))), parity in (0, 1)
    cam = camera(α)
    img = render(cam, ulong, parity, sar)
    h, w = size(img)
    for nc in ((10, 7), (7, 10))
        corners = R._detect_corners(reshape(img, 1, h, w), nc)
        if ismissing(corners)
            @printf("%-9s  %5.2f  %-14s %d  %.1f | not detected\n", string(nc), α, string(round.(ulong; digits = 2)), parity, sar)
            continue
        end
        W(ij) = backproject(cam, corners[ij...][1], corners[ij...][2], sar)
        O = W((1, 1))
        ei = (W((2, 1)) - O) / CW
        ej = (W((1, 2)) - O) / CW
        dq = sign(ei[1] * ej[2] - ei[2] * ej[1])
        @printf("%-9s  %5.2f  %-14s %d  %.1f | (%+.2f,%+.2f)  (%+.2f,%+.2f)  %+d   (%+.3f,%+.3f)\n",
            string(nc), α, string(round.(ulong; digits = 2)), parity, sar, ei..., ej..., dq, O...)
    end
end
