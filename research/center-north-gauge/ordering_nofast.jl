# Same probe at sar != 1, where Fromage's _detect_corners (FAST_CHECK) found nothing: call
# findChessboardCorners with Fromage's flags minus FAST_CHECK, to see the ordering OpenCV would give.
src = read(joinpath(dirname(abspath(PROGRAM_FILE)), "ordering.jl"), String)
include_string(Main, split(src, "println(\"n_corners")[1])
function detect_nofast(img, nc)
    h, w = size(img)
    gry = R.OpenCV.Mat(reshape(img, 1, h, w))
    corners = Matrix{Fromage.Spaces.RowCol}(undef, nc)
    ret, _ = R.OpenCV.findChessboardCorners(gry, R.OpenCV.Size{Int32}(nc...),
        R.OpenCV.Mat(reshape(reinterpret(Float32, corners), 2, 1, prod(nc))),
        R.OpenCV.CALIB_CB_ADAPTIVE_THRESH + R.OpenCV.CALIB_CB_NORMALIZE_IMAGE)
    return ret ? corners : missing
end
n = 0; npos = 0; nmiss = 0
for sar in (2.0, 0.5, 64 / 45, 10 / 11), α in (0.0, π / 2, π, 3π / 4), ulong in (SVector(0.0, 1.0), SVector(1.0, 0.0), normalize(SVector(1.0, 1.0))), parity in (0, 1)
    cam = camera(α)
    img = render(cam, ulong, parity, sar)
    for nc in ((10, 7), (7, 10))
        corners = detect_nofast(img, nc)
        fromage = R._detect_corners(reshape(img, 1, size(img)...), nc)
        if ismissing(corners)
            global nmiss += 1
            continue
        end
        W(ij) = backproject(cam, corners[ij...][1], corners[ij...][2], sar)
        O = W((1, 1)); ei = W((2, 1)) - O; ej = W((1, 2)) - O
        dq = sign(ei[1] * ej[2] - ei[2] * ej[1])
        global n += 1; global npos += dq > 0
        @printf("sar=%.3f α=%.2f long=%s parity=%d nc=%s  detQ=%+d origin=(%+.3f,%+.3f)  fromage_detects=%s\n",
            sar, α, string(round.(ulong; digits = 2)), parity, string(nc), dq, O..., !ismissing(fromage))
    end
end
println("detected without FAST_CHECK: $n, of which detQ=+1: $npos; missed even without FAST_CHECK: $nmiss")
