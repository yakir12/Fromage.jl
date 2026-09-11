# The rectification diagnostic image, end to end: the warp transform, the warped extrinsic frame,
# and the save. `save_diagnostic` used to sit at the bottom of from_checkerboard.jl even though
# every builder called it and both its helpers live here; since #209 no builder calls it at all.

function get_warp(ratio, real2image)
    D = LinearMap(SDiagonal{2}(ratio * I))
    return real2image ∘ D
end

function warp_extrinsic(file, extrinsic, width, height, warp_trans)
    m = min(width, height)
    _img = _frame_at(file, extrinsic, missing, width, height)
    img = colorview(Gray, normedview(_img))
    return imgw = warp(img, warp_trans, ((-m ÷ 2):(m ÷ 2), (-m ÷ 2):(m ÷ 2)))
end

# Save the warped extrinsic frame — a quick visual check that the rectification looks right,
# available as soon as the rectification is built rather than after every run has been tracked.
#
# Called by `build_rectifications`, never by a builder (#209). Everything the warp needs —
# `width`, `height`, `ratio`, `real2image` — is a field of the `StaticRectification` the builder has
# already returned, so nothing has to be threaded down for it. That spares `from_matlab`,
# `from_uniform` and `_rectification` the three arguments only this image ever wanted (`file`,
# `extrinsic`, `rectification_id`); `from_checkerboard`/`from_extrinsic` still take `file` and
# `extrinsic`, which they read the video with. Whether to render at all is the caller's decision, so
# this function no longer takes `rectification_diagnostics`: there is nothing here to switch off.
#
# Dispatch, not a branch: the other method is the AprilTag no-op, which cannot be written here
# because `Rectifications` is included before `PawsomeTracker` — see PawsomeTracker/apriltag.jl.
#
# The file is named by `rectification_id`, which is what lets a reader match an image back to its csv
# row — and is unique, where the video/extrinsic pair this used to be named after is not: two video
# rows differing only in `center` are not duplicates by `verify_unique_rectifications!` and warp
# differently, so one would have silently overwritten the other.
#
# `mkpath` here rather than in the caller keeps the function correct when called on its own, and is
# safe under `build_rectifications`' `tmap`: it tolerates the directory already existing.
function save_diagnostic(rectification::StaticRectification, file, extrinsic, rectification_id)
    warp_trans = get_warp(rectification.ratio, rectification.real2image)
    imgw = warp_extrinsic(file, extrinsic, rectification.width, rectification.height, warp_trans)
    mkpath(RECTIFICATIONS_DIR)
    FileIO.save(joinpath(RECTIFICATIONS_DIR, string(rectification_id, ".jpg")), parent(imgw))
    return
end
