# PROTOTYPE PROBE — why does findChessboardCorners miss the rendered board?
using Fromage: Fromage
const OpenCV = Fromage.Rectifications.OpenCV
using FFMPEG: FFMPEG
using StaticArrays: SVector

png = ARGS[1]
w, h = parse.(Int, split(ARGS[2], "x"))
nc = (parse(Int, ARGS[3]), parse(Int, ARGS[4]))

buf = read(`$(FFMPEG.ffmpeg()) -hide_banner -loglevel error -i $png -frames:v 1 -f rawvideo -pix_fmt gray pipe:1`)
img = permutedims(reshape(buf, w, h))          # h×w, as Fromage reads it
println("frame $(size(img)), gray range $(extrema(img))")

function try_detect(mat, nc, flags, label)
    o = Matrix{SVector{2, Float32}}(undef, nc)
    ret, _ = OpenCV.findChessboardCorners(
        mat, OpenCV.Size{Int32}(nc...),
        OpenCV.Mat(reshape(reinterpret(Float32, o), 2, 1, prod(nc))), flags
    )
    println(rpad(label, 52), ret ? "FOUND" : "missed")
    return ret
end

F = OpenCV
transposed = OpenCV.Mat(reshape(img, 1, h, w))   # what Fromage passes
upright = OpenCV.Mat(reshape(permutedims(img), 1, w, h))

for (name, mat) in (("transposed view (Fromage's)", transposed), ("upright view", upright))
    for n in (nc, reverse(nc))
        try_detect(mat, n, F.CALIB_CB_ADAPTIVE_THRESH + F.CALIB_CB_NORMALIZE_IMAGE + F.CALIB_CB_FAST_CHECK, "$name, n=$n, Fromage's flags")
        try_detect(mat, n, F.CALIB_CB_ADAPTIVE_THRESH + F.CALIB_CB_NORMALIZE_IMAGE, "$name, n=$n, no FAST_CHECK")
        try_detect(mat, n, Int32(0), "$name, n=$n, no flags")
    end
end

# the modern detector, for comparison
for n in (nc, reverse(nc))
    o = Matrix{SVector{2, Float32}}(undef, n)
    try
        ret, _ = OpenCV.findChessboardCornersSB(
            transposed, OpenCV.Size{Int32}(n...),
            OpenCV.Mat(reshape(reinterpret(Float32, o), 2, 1, prod(n))), Int32(0)
        )
        println(rpad("findChessboardCornersSB, n=$n", 52), ret ? "FOUND" : "missed")
    catch e
        println("findChessboardCornersSB n=$n threw: ", sprint(showerror, e))
    end
end
