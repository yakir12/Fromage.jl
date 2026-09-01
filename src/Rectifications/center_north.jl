function i2r_centering(image2real, c)
    cxy = image2real(c)
    Translation(-cxy)
end

i2r_northing(_, _, ::Missing) = IdentityTransformation()
function i2r_northing(image2real, centering, n)
    fc = centering ∘ image2real
    p = fc(n)
    LinearMap(Angle2d(π - atan(p[2], p[1])))
end

function i2r_centering_northing(image2real, c, n)
    centering = i2r_centering(image2real, c)
    northing = i2r_northing(image2real, centering, n)
    return (centering, northing)
end

# `center`/`north` are DISPLAY pixels, (x, y) — what you read off a screen showing the video at its
# true shape. The maps work in STORED pixels, (row, col), and display x = stored col × aspect, so the
# x is divided on the way in. This used to multiply, which displaced every anamorphic rectification
# by (aspect - 1) × x — half a frame at sar 2 (#130).
#
# Display space is not an arbitrary pick: `center` doubles as the default start_location for the
# calibration's runs, and `start_location` is display space, so the two must agree.
fix_coordinate(::Missing, _) = missing
function fix_coordinate(xy, aspect)
    x, y = xy
    (y, x / aspect)
end

# When no `center` is supplied (`missing`), default it to the frame centre — expressed in the same
# display pixels `center`/`north` use, so that `fix_coordinate` converts it back to the true stored
# centre (width/2, height/2).
default_center(center, _, _, _) = center
default_center(::Missing, width, height, aspect) = SVector{2,Float64}(width * aspect / 2, height / 2)


function add_center_north(image2real, real2image, center, north, aspect)
    centering, northing = i2r_centering_northing(image2real, fix_coordinate(center, aspect), fix_coordinate(north, aspect))
    real2image = ∘(real2image, inv(centering), inv(northing))
    image2real = northing ∘ centering ∘ image2real
    return image2real, real2image
end
