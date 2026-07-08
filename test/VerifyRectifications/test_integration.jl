# The whole point of the gateway: every RectificationMethod a clean load returns must be consumable
# by Rectifications. This pins the cross-package contract end to end — in particular the `missing`
# sentinel for omitted center/north (which Rectifications must default/ignore, not choke on) and
# the Bool yadif (false must not deinterlace). MATLAB is excluded until Rectification(c::MATLAB)
# is implemented.
using Fromage.Rectifications: Rectification

@testset "integration: clean loads build Rectifications" begin

    @testset "only_scale, with and without center/north" begin
        for (name, r) in (("cn", scalerow()), ("nocn", scalerow(center = missing, north = missing)))
            cs = check("int_scale_$name.csv", [r])
            @test cs isa Vector                          # clean load ⇒ structs, not an issues df
            rect = Rectification(only(cs))
            p = [100.0, 120.0]
            @test rect.real2image(rect.image2real(p)) ≈ p    # the maps invert each other
            @test rect.ratio == 9.5                          # only_scale carries the scale through
            @test (rect.width, rect.height) == (640, 480)    # probed source-video frame size
        end
    end

    @testset "video, with and without center/north" begin
        for (name, r) in (("cn", videorow()), ("nocn", videorow(center = missing, north = missing)))
            cs = check("int_video_$name.csv", [r])
            @test cs isa Vector
            rect = Rectification(only(cs))               # full pipeline: reads, detects, fits
            @test rect.image2real isa Function
            @test rect.real2image isa Function
            @test (rect.width, rect.height) == (500, 376)
        end
    end

    @testset "video without a calibs window ⇒ extrinsics-only rectification" begin
        # both window bounds blank is a valid, supported configuration: it selects the
        # Video{Missing} variant, whose Rectification fits pose + focal from the single extrinsic
        # frame and disregards lens aberrations (zero distortion).
        cs = check("int_video_extonly.csv", [videorow(start = missing, stop = missing)])
        @test cs isa Vector
        c = only(cs)
        @test c isa VRect.Video{Missing}
        rect = Rectification(c)
        @test rect.image2real isa Function
        @test rect.real2image isa Function
        @test (rect.width, rect.height) == (500, 376)
    end
end
