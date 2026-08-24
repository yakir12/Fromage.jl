# The simplest rectification: a uniform `scale` (real-world units per pixel) and the pixel aspect
# ratio, with no camera model at all. `file`/`extrinsic` are used only to render the diagnostic
# frame. Keyword-only, like every builder here — see the note above the dispatchers in
# VerifyRectifications/types.jl.
function from_scale(; file, extrinsic, calibration_id, scale, aspect, center, north, width, height,
        rectification_diagnostics::Bool)
    image2real = LinearMap(scale * SDiagonal(SVector{2, Float64}(1, aspect)))
    real2image = inv(image2real)
    center = default_center(center, width, height, aspect)
    image2real, real2image = add_center_north(image2real, real2image, center, north, aspect)
    # `scale` is this method's units-per-pixel, i.e. its `ratio` — the same argument the other
    # builders hand `_diagnostic`. This used to repeat that function's body inline, and computed the
    # warp transform on every call whether or not a diagnostic was wanted.
    _diagnostic(rectification_diagnostics, file, extrinsic, calibration_id, width, height, scale, real2image)
    return (; image2real, real2image, ratio = scale, width, height)
end

