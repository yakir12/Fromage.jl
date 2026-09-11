function i2r_centering(image2real, c)
    cxy = image2real(c)
    return Translation(-cxy)
end

i2r_northing(_, _, ::Missing) = IdentityTransformation()
function i2r_northing(image2real, centering, n)
    fc = centering ∘ image2real
    p = fc(n)
    return LinearMap(Angle2d(π - atan(p[2], p[1])))
end

function i2r_centering_northing(image2real, c, n)
    centering = i2r_centering(image2real, c)
    northing = i2r_northing(image2real, centering, n)
    return (centering, northing)
end

# `center`/`north` are DISPLAY pixels, (x, y) — what you read off a screen showing the video at its
# true shape. The maps work in STORED pixels, (row, col), so both the swap and the `aspect` division
# are `Spaces.to_stored`'s job; this file used to spell that conversion out itself, and #130 was
# that copy multiplying where the tracker's copy divided.
#
# Display space is not an arbitrary pick: `center` doubles as the default start_location for the
# rectification's runs, and `start_location` is display space, so the two must agree.
#
# When no `center` is supplied (`missing`), default it to the frame centre — expressed in the same
# display pixels `center`/`north` use, so that `to_stored` converts it back to the true stored
# centre, (height/2, width/2). Stored is (row, col), so the row comes first: writing that pair the
# other way round is the transposition this whole file exists to get right.
#
# The x half is `Spaces.display_center_x`, shared with `VerifyRuns.frame_center`, which computes the
# same centre and then rounds it differently — that one truncates to an Int start location, this one
# keeps the exact Float64 half. The shared function returns the value they disagree about; the
# rounding stays here, where you can see it.
default_center(center, _, _, _) = center
default_center(::Missing, width, height, aspect) = SVector{2, Float64}(display_center_x(width, aspect), height / 2)


function add_center_north(image2real, real2image, center, north, aspect)
    centering, northing = i2r_centering_northing(image2real, to_stored(center, aspect), to_stored(north, aspect))
    real2image = ∘(real2image, inv(centering), inv(northing))
    image2real = northing ∘ centering ∘ image2real
    return image2real, real2image
end
