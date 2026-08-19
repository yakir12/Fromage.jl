# The simplest rectification: a uniform `scale` (real-world units per pixel) and the pixel aspect
# ratio, with no camera model at all. `file`/`extrinsic` are used only to render the diagnostic
# frame. Keyword-only, like every builder here — see the note above the dispatchers in
# VerifyRectifications/types.jl.
function from_scale(; file, extrinsic, scale, aspect, center, north, width, height, diagnostic = nothing)
    image2real = LinearMap(scale * SDiagonal(SVector{2, Float64}(1, aspect)))
    real2image = inv(image2real)
    center = default_center(center, width, height)
    image2real, real2image = add_center_north(image2real, real2image, center, north, aspect)
    warp_trans = get_warp(scale, real2image)
    if !isnothing(diagnostic)
        imgw = warp_extrinsic(file, extrinsic, width, height, warp_trans)
        FileIO.save(joinpath(diagnostic, string(first(splitext(basename(file))), "_$extrinsic.jpg")), parent(imgw))
    end
    return (; image2real, real2image, ratio = scale, width, height)
end

