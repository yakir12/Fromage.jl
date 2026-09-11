# The simplest rectification: a uniform `pixel_width` (the real-world width of one displayed
# pixel) and the pixel aspect ratio, with no camera model at all. It reads nothing at all: the source
# video was only ever here for the diagnostic frame, which the caller renders since #209, so
# `file`/`extrinsic`/`rectification_id` are gone from the signature. Keyword-only, like every
# builder here — see the note above the dispatchers in VerifyRectifications/types.jl.
#
# `pixel_width` is this method's units-per-pixel, i.e. its `ratio`, which is why it fills that slot
# of the returned `StaticRectification`.
function from_uniform(; pixel_width, aspect, center, north, width, height)
    image2real = LinearMap(pixel_width * SDiagonal(SVector{2, Float64}(1, aspect)))
    real2image = inv(image2real)
    center = default_center(center, width, height, aspect)
    image2real, real2image = add_center_north(image2real, real2image, center, north, aspect)
    return StaticRectification(image2real, real2image, pixel_width, width, height)
end
