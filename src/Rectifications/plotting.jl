# The rectification diagnostic image, end to end: the warp transform, the warped extrinsic frame,
# and the save that `rectification_diagnostics` asks for. `_diagnostic` used to sit at the bottom of
# from_checkerboard.jl even though every builder calls it and both its helpers live here.

function get_warp(ratio, real2image)
    D = LinearMap(SDiagonal{2}(ratio*I))
    real2image ∘ D
end

function warp_extrinsic(file, extrinsic, width, height, warp_trans)
    m = min(width, height)
    _img = _frame_at(file, extrinsic, missing, width, height)
    img = colorview(Gray, normedview(_img))
    imgw = warp(img, warp_trans, (-m÷2:m÷2, -m÷2:m÷2))
end

# Save the warped extrinsic frame (a no-op unless asked) — a quick visual check that the
# rectification looks right, available as soon as the rectification is built rather than after every
# run has been tracked. `rectification_diagnostics` is the same flag `main` takes, passed straight
# down, so there is one name and one type for it the whole way.
#
# The file is named by `calibration_id`, which is what lets a reader match an image back to its csv
# row — and is unique, where the video/extrinsic pair this used to be named after is not: two video
# rows differing only in `center` are not duplicates by `verify_unique_calibrations!` and warp
# differently, so one would have silently overwritten the other.
#
# `mkpath` here rather than in the caller keeps the function correct when called on its own, and is
# safe under the builders' `tmap`: it tolerates the directory already existing.
function _diagnostic(rectification_diagnostics, file, extrinsic, calibration_id, width, height, ratio, real2image)
    rectification_diagnostics || return
    imgw = warp_extrinsic(file, extrinsic, width, height, get_warp(ratio, real2image))
    mkpath(RECTIFICATIONS_DIR)
    FileIO.save(joinpath(RECTIFICATIONS_DIR, string(calibration_id, ".jpg")), parent(imgw))
    return
end
