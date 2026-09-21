# Rectified tracks against real-world coordinates computed without the package (#276).
#
# A tracked point is an array index, and every map is fitted to 0-based pixels, so the two meet at
# `Spaces.from_index`. Before #276 nothing converted: each rectified point was evaluated one stored
# pixel down and right of the target. No other test could see it, because each built its expected
# track by pushing the fixture's own pixel path through the package's own maps, so the expectation
# shared the convention it was checking. And `test_anamorphic.jl` takes the best rigid motion out
# before comparing, which absorbs a constant shift.
#
# Here the truth comes from the fixtures' cameras alone. `center` pins the origin, and with no
# `north` the only freedom left is which way the fitted axes point: one of the eight signed axis
# permutations, a discrete choice that cannot absorb a sub-unit shift. The test picks the best
# of the eight and bounds what remains.
module PixelOriginTests

using Test
using Fromage: Fromage
using StaticArrays: SVector, SMatrix
using Statistics: mean
using ..Fixtures: CHECKERBOARD_POSES, make_squeezed_checkerboard_video, make_squeezed_disc_video,
    make_apriltag_video, pose_apply, track1, TAG_CELL

const R = Fromage.Rectifications
const PT = Fromage.PawsomeTracker

# The eight signed permutations of two axes: every way a fitted frame's axes can point.
const AXES = [
    SMatrix{2, 2, Float64}(a, 0, 0, b) * P for a in (1, -1), b in (1, -1),
        P in (SMatrix{2, 2, Float64}(1, 0, 0, 1), SMatrix{2, 2, Float64}(0, 1, 1, 0))
]

# RMS distance from the track to the truth, under the axis choice that fits best.
function best_axes_rms(track, truth)
    return minimum(AXES) do D
        sqrt(mean(sum(abs2, SVector{2}(t) - D * s) for (t, s) in zip(track, truth)))
    end
end

@testset "rectified tracks have no pixel-origin bias (#276)" begin
    @testset "checkerboard" begin
        # A disc 0.7 squares across slides over the extrinsic board plane (pose 13), filmed by the
        # calibration clip's camera; #276 measured this geometry. One square spans ~62 display px
        # at that depth, so the disc is ~44 px wide, and one display px is ~0.4 mm on 25 mm squares.
        n_corners = (7, 6)
        checker_width = 25.0
        nframes = 30
        board_path(k) = (1.0 + 4.0 * (k - 1) / (nframes - 1), 1.5 + 2.0 * (k - 1) / (nframes - 1))
        center = (320, 240)
        mktempdir() do dir
            # Measured RMS (mm), before #276 → after: 0.553 → 0.028 at sar = 1, 0.714 → 0.225 at
            # sar = 2. The bound at sar = 1 is #276's. What remains at sar = 2 is `Spaces.stored_x`'s
            # `x / sar`, which puts `center` 0.25 stored columns from the area-exact column, about
            # 0.2 mm here. That was kept deliberately (DECISIONS), so its bound sits above it and
            # still far below the bias.
            @testset "sar = $sar" for (sar, bound) in ((1 // 1, 0.15), (2 // 1, 0.3))
                tag = "$(numerator(sar))_$(denominator(sar))"
                camera = (; sar, f = 1000.0, width = 640, height = 480)
                clip = make_squeezed_checkerboard_video(
                    joinpath(dir, "board_$tag.mp4"), CHECKERBOARD_POSES; n_corners, camera...
                )
                disc = make_squeezed_disc_video(
                    joinpath(dir, "disc_$tag.mp4"), CHECKERBOARD_POSES[13];
                    board_path, nframes, diameter = 0.7, camera...
                )
                rect = R.from_checkerboard(;
                    file = clip.file, extrinsic = 1.15, yadif = missing, blur = missing,
                    width = clip.stored_width, height = 480, n_corners, checker_width,
                    aspect = Float64(sar), center, north = missing,
                    intrinsic_start = 0.05, intrinsic_stop = 1.05, temporal_step = 0.1, radial_parameters = 1
                )
                # the board point under `center`, which is where the real-world origin must land
                origin = SVector(disc.board(center...))
                truth = [checker_width * (SVector(board_path(k)) - origin) for k in 1:nframes]
                # the disc's first position as a user would read it off the screen: display (x, y)
                row, col = disc.stored(board_path(1)...)
                start_location = (round(Int, (col + 0.5) * sar - 0.5), round(Int, row))
                _, xy = track1(disc.file; rectification = rect, start_location, target_width = 44)
                @test best_axes_rms(xy, truth) < bound
            end
        end
    end

    @testset "AprilTag" begin
        # The drone fixture's ground canvas is the truth. `tag_cell_width = TAG_CELL` makes one metric
        # unit one ground pixel, and `center` names the reference-frame pixel whose ground position
        # `inv(poses[1])` gives. `poses` map 1-based render pixels, so `center`, which is 0-based
        # as a user reads it, goes in plus one.
        nframes = 40
        mktempdir() do dir
            v = make_apriltag_video(dir, "origin"; nframes, tw = 12)
            file = joinpath(dir, v.file)
            center = (240, 240)
            rect = PT.ApriltagRectification(;
                aspect = 1.0, file, extrinsic = 0, ntags = 4, family = "tag36h11",
                tag_cell_width = TAG_CELL, center, north = missing, width = 480, height = 480
            )
            origin = pose_apply(inv(v.poses[1]), center .+ 1)
            truth = [v.ground_xy(k) - origin for k in 1:nframes]
            _, xy = track1(file; rectification = rect, start_location = v.start_location, target_width = 12)
            @test !any(ismissing, xy)
            # Measured RMS (ground px), before #276 → after: 1.41 → 0.077.
            @test best_axes_rms(xy, truth) < 0.3
        end
    end
end

end
