using Test
using Dates
using Exiftool_jll

function get_recording_datetime(file)
    txts = strip.(split(read(`$(exiftool()) -T -AllDates -n $file`, String), '\t'))
    dts = [DateTime(txt[1:19], DateFormat("yyyy:mm:dd HH:MM:SS")) for txt in txts if length(txt) > 18]
    if isempty(dts)
        return missing
    else
        minimum(dts)
    end
end
file = "a.png"
@test get_recording_datetime(file) == DateTime(2024, 12, 13, 9, 38, 5)
