function get_sun(jds, latitude, longitude, altitude)
    right_ascension, declination = sunpos(jds)
    altaz = eq2hor.(right_ascension, declination, jds, latitude, longitude, altitude)
end

dt2julian(dt, tz) = TimeZones.zdt2julian(ZonedDateTime(dt, tz))

function get_sun_elevation_azimuth(dt, latitude, longitude, altitude, tz)
    jd = dt2julian(dt, tz)
    elevation, azimuth, _ = get_sun(jd, latitude, longitude, altitude)
    return (elevation, azimuth)
end

get_sun_elevation_azimuth(dt, station) = get_sun_elevation_azimuth(dt, station["latitude"], station["longitude"], station["altitude"], TimeZone(station["timezone"]))
