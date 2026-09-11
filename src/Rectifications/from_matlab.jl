# Depth-first search for `k` through a nested .mat structure, returning the VALUE or `nothing`.
# Three methods rather than one `isa` chain: the containers a .mat can nest are exactly these, and
# anything else is a leaf that cannot hold the key.
#
# `nothing` is an unambiguous "absent" here because a .mat value is never `nothing` — MAT.jl yields
# numbers, arrays, strings and dicts. (It used to return `k => value`, and both callers immediately
# threw the key away with `last`.)
#
# It lives here, beside the one function that reads a .mat, rather than in VerifyRectifications
# (which is where it started, and which still uses it). The builder and the verification MUST agree
# on which value a field name resolves to: while the builder unwrapped a single-key top-level struct
# with its own loop and the verification searched recursively, a .mat carrying the calibration
# alongside any second variable passed every check and then raised `KeyError: key "K" not found`
# from `from_matlab` — a valid calibration, refused with a low-level error (#152).
findfirstkey(::Any, _) = nothing

function findfirstkey(d::AbstractDict, k)
    haskey(d, k) && return d[k]                   # check current level first
    for v in values(d)
        r = findfirstkey(v, k)
        isnothing(r) || return r
    end
    return nothing
end

function findfirstkey(d::Union{AbstractVector, Tuple}, k)
    for v in d
        r = findfirstkey(v, k)
        isnothing(r) || return r
    end
    return nothing
end

# How many values `k` could resolve to — mirroring `findfirstkey`'s precedence exactly, so it counts
# only the choices `findfirstkey` would actually have to make: a level that holds the key itself is
# one, unambiguously, and the search never descends past it.
#
# One is the only usable answer. MATLAB's stereo `stereoParams` nests two complete calibrations
# (`CameraParameters1` and `CameraParameters2`), and a Dict's values have no order the user chose, so
# `findfirstkey` would pick a camera essentially at random — and verification and construction, being
# separate `matread` calls, are not even guaranteed to pick the same one. Fromage has no stereo notion
# and no way to tell which camera filmed the video, so this is a file to refuse, not to resolve (#152).
countkeys(::Any, _) = 0
countkeys(d::AbstractDict, k) = haskey(d, k) ? 1 : sum(v -> countkeys(v, k), values(d); init = 0)
countkeys(d::Union{AbstractVector, Tuple}, k) = sum(v -> countkeys(v, k), d; init = 0)

# Rectification from a MATLAB Camera Calibrator `.mat` file: the camera model — intrinsics (K),
# radial distortion, and the extrinsic pose selected by `extrinsic_index` — is read from the file
# instead of being fit from a checkerboard video. The extraction (including the MATLAB axis and
# angle conventions) is ported untouched from CameraCalibrations.jl's `loadMAT`. Real-world
# coordinates come out in the `.mat`'s own world units (whatever square size the MATLAB
# calibration was given), so the unit scale is 1. The source video plays no part here at all — it
# was only ever carried for the diagnostic frame, which the caller renders since #209.
function from_matlab(; matlab_file, extrinsic_index, aspect, center, north, width, height)
    dict = matread(matlab_file)
    # the Camera Calibrator wraps everything in a top-level struct (e.g. "cameraParams"), so every
    # field is looked up by name wherever it sits — the same lookup VerifyRectifications used to
    # verify it. That gateway has already established that each field exists, nested or not, and has
    # the shape indexed below: K is 3×3, both pose stacks are N×3 with 1 ≤ extrinsic_index ≤ N, and
    # RadialDistortion holds one to three coefficients (`matlab_intrinsics_issue`,
    # `matlab_extrinsic_count`, #152).
    K = findfirstkey(dict, "K")
    fcol = K[1, 1]
    frow = K[2, 2]
    ccol = K[1, 3]
    crow = K[2, 3]

    # both of these have their x and y the other way around, due to some matlab convention
    R = -Vector{Float64}(findfirstkey(dict, "RotationVectors")[extrinsic_index, [2, 1, 3]])   # negative due to some matlab angle convention...
    t = Vector{Float64}(findfirstkey(dict, "TranslationVectors")[extrinsic_index, [2, 1, 3]])

    # matlab writes 2 or 3 radial coefficients; pad to the model's three with an explicit zero so
    # `k` has one concrete type whatever the file said. Zero-padding is exactly identity here —
    # verified that `_first_critical`, `lens_distortion` and `inv_lens_distortion` are bit-identical
    # for (k1, k2) and (k1, k2, 0.0), including the folded and non-folded regimes. A file with MORE
    # than three never arrives: the gateway rejects it rather than let this quietly drop the tail
    # (#152, and DECISIONS, "A `.mat` with four radial coefficients is rejected, not truncated").
    radial = vec(findfirstkey(dict, "RadialDistortion"))
    k = ntuple(i -> i ≤ length(radial) ? Float64(radial[i]) : 0.0, 3)

    cam = CameraModel(; R, t, frow, fcol, crow, ccol, k)
    # `checker_width = 1`: the .mat's world units ARE the output units, so there is no square size
    # to divide by (see the note above about the unit scale).
    image2real, real2image = _maps(cam; checker_width = 1, width, height, aspect, center, north)
    # units-per-pixel at the arena centre — the matlab analogue of the video path's
    # checker_width/checker_width_pixel (there are no detected corners to measure it from): one
    # real-world unit step at the origin spans 1/ratio pixels
    ratio = 1 / norm(real2image(SVector(1.0, 0.0)) - real2image(SVector(0.0, 0.0)))
    return StaticRectification(image2real, real2image, ratio, width, height)
end
