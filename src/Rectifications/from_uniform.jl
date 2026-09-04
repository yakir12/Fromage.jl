# The simplest rectification: a uniform `pixel_width` (the real-world width of one displayed
# pixel) and the pixel aspect ratio, with no camera model at all. `file`/`extrinsic` are used only to render the diagnostic
# frame. Keyword-only, like every builder here — see the note above the dispatchers in
# VerifyRectifications/types.jl.
function from_uniform(; file, extrinsic, calibration_id, pixel_width, aspect, center, north, width, height,
        rectification_diagnostics::Bool)
    image2real = LinearMap(pixel_width * SDiagonal(SVector{2, Float64}(1, aspect)))
    real2image = inv(image2real)
    center = default_center(center, width, height, aspect)
    image2real, real2image = add_center_north(image2real, real2image, center, north, aspect)
    # `pixel_width` is this method's units-per-pixel, i.e. its `ratio` — the same argument the other
    # builders hand `_diagnostic`. This used to repeat that function's body inline, and computed the
    # warp transform on every call whether or not a diagnostic was wanted.
    _diagnostic(rectification_diagnostics, file, extrinsic, calibration_id, width, height, pixel_width, real2image)
    return StaticRectification(image2real, real2image, pixel_width, width, height)
end

