# Checkerboard rectifications of anamorphic video, asserted against the real world (#275, #277).
#
# Every other rectification test runs at sar = 1, where the fit's two focal lengths are equal and a
# ratio held in the wrong direction, or a swapped pair, is invisible. Here the clip is squeezed
# physically (`make_squeezed_checkerboard_video`), the builders are handed `aspect = sar` exactly as
# the gateway imputes it, and board points whose stored pixels come from the true camera are mapped
# through `image2real` and compared with where they really are on the board. Nothing on the truth
# side goes through the package's maps or `Spaces`.
#
# sar = 1 runs alongside as the control: it is the accuracy the anamorphic cases have to match, and a
# failure there would mean the fixture, not the fit, is wrong.

@testset "anamorphic checkerboard rectification" begin
    n_corners = (7, 6)
    checker_width = 25.0
    # 0-based frames 1..11 are the intrinsic views and frame 12 the extrinsic one (pose 13); see
    # `CHECKERBOARD_POSES` for why t = (k − ½)/10 reads frame k.
    extrinsic_pose = 13
    intrinsic_window = (; intrinsic_start = 0.05, intrinsic_stop = 1.05, temporal_step = 0.1, radial_parameters = 1)
    # A 13×11 grid of board points at half-square spacing, in checker units: the inner corners and
    # the centres of the squares between them.
    board = vec([(X, Y) for X in 0:0.5:(n_corners[1] - 1), Y in 0:0.5:(n_corners[2] - 1)])
    # Where those points really are, in mm and in the (y, x) order `image2real` returns (see `XYZ`).
    # The fixture's board `X` runs along display x and `Y` along display y, so that is `(Y, X)`;
    # written `(X, Y)` the comparison sees a mirror image.
    truth = [SVector(Y, X) * checker_width for (X, Y) in board]

    # RMS distance between the mapped points and the truth once the best rigid motion (a proper
    # rotation plus a translation, Kabsch) is taken out. The motion is the free gauge — where the
    # origin and north land — which `center`/`north` settle and other tests pin (#130). A scale error,
    # a stretch along either axis, or a mirror all survive it.
    function rigid_rms(mapped, truth)
        a = mapped .- Ref(sum(mapped) / length(mapped))
        b = truth .- Ref(sum(truth) / length(truth))
        F = svd(sum(ai * bi' for (ai, bi) in zip(a, b)))
        D = SDiagonal(1.0, sign(det(F.V * F.U')))
        Q = F.V * D * F.U'
        return sqrt(sum(sum(abs2, Q * ai - bi) for (ai, bi) in zip(a, b)) / length(a))
    end

    mktempdir() do dir
        @testset "sar = $sar" for sar in (1 // 2, 1 // 1, 2 // 1)
            clip = make_squeezed_checkerboard_video(
                joinpath(dir, "board_$(numerator(sar))_$(denominator(sar)).mp4"), CHECKERBOARD_POSES;
                sar, n_corners, f = 1000.0, width = 640, height = 480
            )
            common = (;
                file = clip.file, extrinsic = 1.15, yadif = missing, blur = missing,
                width = clip.stored_width, height = 480, n_corners, checker_width,
                aspect = Float64(sar), center = missing, north = missing,
            )
            stored = [R.RowCol(clip.stored(extrinsic_pose, X, Y)...) for (X, Y) in board]
            # Measured (from_checkerboard / from_extrinsic, mm): 0.0033 / 0.0032 at sar = 1/2,
            # 0.0048 / 0.0058 at sar = 1, 0.0073 / 0.0087 at sar = 2. Before #275's fix the two
            # anamorphic cases read 0.74 / 0.33 and 0.77 / 0.28. The bound is the one #275 and #277
            # set, on 25 mm squares.
            @testset "$name" for (name, build) in (
                    ("from_checkerboard", () -> R.from_checkerboard(; common..., intrinsic_window...)),
                    ("from_extrinsic", () -> R.from_extrinsic(; common...)),
                )
                rect = build()
                @test rigid_rms([SVector{2}(rect.image2real(p)) for p in stored], truth) < 0.1
            end
        end
    end
end
