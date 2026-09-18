# The ideal sensor (#289): each stored pixel is the mean reflectance over its footprint (a box filter,
# 100 % fill factor), no optical blur, no noise, 8 bit. The mean is explicit supersampling, never an
# interpolation flag: OpenCV's `INTER_AREA` is silently bilinear (#282). Ported from `render` in
# `prototype/baseline-rig:prototype/baseline_rig.jl` (#291).

using OhMyThreads: tforeach
using StaticArrays: SVector

"""
Samples per stored pixel along each axis. 4×4 had not converged; 16×16 moves the detected corners
0.03 px RMS from 32×32, against a 0.07 px detector floor, at 3.5× less cost (#292).
"""
const SUPERSAMPLING = 16

"""
    render(cam::Camera, board; samples = SUPERSAMPLING) -> Matrix{UInt8}

The frame `cam` stores of the rig with `board` in view (a [`Board`](@ref), or `nothing`): a
`cam.height × cam.width` matrix whose `[row + 1, col + 1]` is 0-based stored pixel `(row, col)`.
Each pixel is the mean reflectance over `samples × samples` rays cast backwards through the camera
model, evenly spaced over its stored footprint, which is rectangular in display space when
`cam.sar ≠ 1`. A sample past the lens's fold sees black.

The matrix is column-major, as Julia's are; raw video is row-major, so it is written out transposed.
"""
function render(cam::Camera, board; samples = SUPERSAMPLING)
    img = Matrix{UInt8}(undef, cam.height, cam.width)
    offsets = ((0:(samples - 1)) .+ 0.5) ./ samples .- 0.5
    tforeach(axes(img, 1)) do i
        for j in axes(img, 2)
            acc = 0.0
            for a in offsets, b in offsets
                d = ray(cam, SVector(i - 1 + a, j - 1 + b))
                acc += d === nothing ? 0.0 : trace(board, cam.position, d).reflectance
            end
            img[i, j] = round(UInt8, 255 * acc / samples^2)
        end
    end
    return img
end
