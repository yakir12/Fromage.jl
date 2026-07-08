function i2r_centering(image2real, c)
    cxy = image2real(c)
    Translation(-cxy) 
end

i2r_northing(_, _, ::Missing) = IdentityTransformation()
function i2r_northing(image2real, centering, n)
    fc = centering ∘ image2real
    p = fc(n)
    LinearMap(Angle2d(π - atan(p[2], p[1])))
    # LinearMap(Angle2d(π/2 - atan(p[2], p[1])))
end

function i2r_centering_northing(image2real, c, n)
    centering = i2r_centering(image2real, c)
    northing = i2r_northing(image2real, centering, n)
    return (centering, northing)
end

fix_coordinate(::Missing, _) = missing
function fix_coordinate(xy, aspect)
    x, y = xy
    (y, aspect*x)
end

# When no `center` is supplied (`missing`), default it to the frame centre — in the same (w, h)
# pixel convention `center`/`north` use (width first, height second).
default_center(center, _, _) = center
default_center(::Missing, width, height) = SVector{2,Float64}(width / 2, height / 2)


function add_center_north(image2real, real2image, center, north, aspect)
    centering, northing = i2r_centering_northing(image2real, fix_coordinate(center, aspect), fix_coordinate(north, aspect))
    real2image = ∘(real2image, inv(centering), inv(northing))
    image2real = northing ∘ centering ∘ image2real
    return image2real, real2image
end
