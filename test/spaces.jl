# Unit tests for the coordinate-space conversions (Fromage.Spaces). The callers' own suites still
# pin these through their real call sites — `get_guess` and `fix_window_size` in pawsometracker.jl,
# `frame_center` in VerifyRuns/test_segments.jl, `default_center` and the centre/north round trip in
# Rectifications/test_geometry.jl — and that coverage is the point: a refactor that rewires the call
# sites can break them while every unit test here still passes. These are the other half.
#
# Every assertion is ASYMMETRIC — the two components differ, and sar ≠ 1 wherever sar is involved —
# because that is the only kind that can fail under a transposition (#200).
module SpacesTests

using Test
using Fromage: Fromage
using StaticArrays: SVector

const S = Fromage.Spaces

@testset "Spaces (coordinate conversions)" begin

    @testset "RowCol and GroundXY are one type under two names" begin
        # The AprilTag path stores metric (x, y) in what `track` collects as RowCol, so these MUST
        # stay identical: a distinct type here would split the array type track builds.
        @test S.GroundXY === S.RowCol
        @test S.RowCol === SVector{2, Float32}
    end

    @testset "stored_x divides by sar" begin
        # The direction #130 got backwards: the stored frame is SQUEEZED, so a display x names a
        # SMALLER column. sar 2 ⇒ half, sar 1/2 ⇒ double.
        @test S.stored_x(10, 2.0)  == 5.0
        @test S.stored_x(10, 0.5)  == 20.0
        @test S.stored_x(10, 1.0)  == 10.0
        # multiplying instead of dividing is the actual bug, and is distinguishable at every sar ≠ 1
        @test S.stored_x(10, 2.0) != 10 * 2.0
    end

    @testset "stored_x preserves its caller's number type" begin
        # VerifyRuns holds sar as an exact Rational because it bounds-checks against width × sar;
        # VerifyRectifications holds the Float64 mirroring VideoIO.aspect_ratio. Pinning either in
        # the signature would silently change the other caller's arithmetic.
        @test S.stored_x(10, 1//2) === 20//1
        @test S.stored_x(10, 0.5)  === 20.0
        @test S.stored_x(3, 2//1)  === 3//2      # exact, not 1.5
    end

    @testset "to_stored swaps and corrects" begin
        # display (x, y) ↦ stored (row, col) = (y, x / sar). Both halves have been wrong before:
        # the swap (#198) and the direction of the division (#130).
        @test S.to_stored((3.0, 5.0), 2.0) == (5.0, 1.5)
        @test S.to_stored((3.0, 5.0), 1.0) == (5.0, 3.0)
        # asymmetric at sar 1 too, so a missing swap fails even on square pixels
        @test S.to_stored((120, 30), 1.0) == (30, 120.0)
        # a transposed implementation would give (x / sar, y) — distinguishable from both above
        @test S.to_stored((3.0, 5.0), 2.0) != (1.5, 5.0)
    end

    @testset "to_stored returns a Tuple, whatever it is given" begin
        # `default_center` hands it an SVector and `add_center_north` feeds the result to the
        # centre/north helpers; `get_guess` hands it an NTuple. Both came out as Tuples before.
        @test S.to_stored(SVector(640.0, 240.0), 2.0) === (240.0, 320.0)
        @test S.to_stored((640, 240), 2.0)            === (240, 320.0)
    end

    @testset "to_stored passes `missing` through" begin
        # `center` and `north` are optional, so "no point" has to survive the conversion rather
        # than becoming a MethodError inside the gauge.
        @test S.to_stored(missing, 2.0) === missing
        @test S.to_stored(missing, 1//1) === missing
    end

    @testset "display_center_x is half the DISPLAY width" begin
        # display width = width × sar, so an anamorphic frame's centre is not width/2.
        @test S.display_center_x(640, 1.0) == 320.0
        @test S.display_center_x(640, 2.0) == 640.0     # 640 stored columns display 1280 wide
        @test S.display_center_x(640, 0.5) == 160.0
        # exact and unrounded: its two callers round differently and this must not pick for them
        @test S.display_center_x(101, 1//1) === 101//2
        @test S.display_center_x(101, 1.0)  === 50.5
    end

    @testset "to_stored ∘ display_center_x round-trips to the stored centre" begin
        # The property that ties the two together, and the one #130 broke: the display centre,
        # converted back, is the true stored centre (height/2, width/2) — note the ORDER.
        for (w, h, sar) in ((640, 480, 2.0), (640, 480, 0.5), (100, 50, 1.0))
            @testset "$(w)x$(h) at sar $sar" begin
                display = (S.display_center_x(w, sar), h / 2)
                @test S.to_stored(display, sar) == (h / 2, w / 2)
            end
        end
    end
end

end
