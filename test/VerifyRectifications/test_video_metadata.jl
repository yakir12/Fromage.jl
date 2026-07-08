@testset "video metadata (yadif, width, height, aspect)" begin
    # One ffprobe per video file (probe_video) supplies width/height/duration/aspect/yadif. width/height
    # are always taken from the video (the frame size used to decode it) and have no CSV column; aspect
    # and yadif are imputed from the probe when their CSV cell is blank and kept verbatim otherwise.
    # yadif marks interlaced footage and is not otherwise constrained.

    @testset "probe_video reads interlacing and frame size" begin
        prog = VRect.probe_video(joinpath(DATADIR, ART.board))        # checkerboard, progressive
        @test prog.yadif == false
        @test prog.width > 0 && prog.height > 0

        inter = VRect.probe_video(joinpath(DATADIR, ART.interlaced))  # field_order tt
        @test inter.yadif == true
        @test inter.width == 720
        @test inter.height == 576
    end

    @testset "parse_sample_aspect mirrors VideoIO's SAR fallback" begin
        @test VRect.parse_sample_aspect("1:1") == 1.0
        @test VRect.parse_sample_aspect("4:3") ≈ 4 / 3
        @test VRect.parse_sample_aspect("0:1") == 1.0   # zero -> default 1
        @test VRect.parse_sample_aspect("1:0") == 1.0   # zero denominator -> default 1
        @test VRect.parse_sample_aspect("N/A") == 1.0   # undefined -> default 1
    end

    @testset "missing yadif/width/height are imputed onto the Video struct" begin
        # A clean load returns Vector{Video}; with the columns left blank they are filled from the probe.
        probed = VRect.probe_video(joinpath(DATADIR, ART.board))
        result = check("vm_impute.csv", [videorow()])
        @test result isa Vector
        v = first(result)
        @test v.yadif == false                       # board is progressive (yadif stays on Video)
        @test v.source.width == probed.width
        @test v.source.height == probed.height
        @test v.source.aspect == 1.0                 # square pixels -> SAR 1:1
    end

    @testset "a CSV-supplied yadif wins over the probe; width/height are always probed" begin
        # board is progressive, but an explicit yadif cell must be kept verbatim, not overwritten.
        # width/height have no CSV column, so they always come from the probe (the real frame size).
        probed = VRect.probe_video(joinpath(DATADIR, ART.board))
        result = check("vm_provided.csv", [videorow(yadif = true)])
        @test result isa Vector
        v = first(result)
        @test v.yadif == true                         # provided, not the probed false
        @test v.source.width == probed.width          # always the probed frame width
        @test v.source.height == probed.height        # always the probed frame height
    end

    @testset "a non-boolean yadif is a parse issue, never thrown" begin
        @test flagged(check("vm_yadif_bad.csv", [videorow(yadif = "maybe")]), 1, "wrong yadif format")
    end

    @testset "a CSV-supplied aspect wins over the probe" begin
        # board.mp4 has square pixels (probe aspect 1.0); an explicit CSV aspect must be kept verbatim.
        result = check("vm_aspect_provided.csv", [videorow(aspect = 2.0)])
        @test result isa Vector
        @test first(result).source.aspect == 2.0
    end

    @testset "only_scale and matlab rows now carry imputed width/height (but not yadif)" begin
        # width/height live in the shared Source struct, so they are imputed from the source video for
        # every type now; yadif (interlacing) remains a video-only field. The clean load returns the
        # structs, so inspect c[1].source.width/height.
        probed = VRect.probe_video(joinpath(DATADIR, ART.video))   # video.mp4: 640×480
        for (name, r) in (("scale", scalerow()), ("matlab", matlabrow()))
            c = check("vm_$name.csv", [r])
            @test c isa Vector
            @test c[1].source.width  == probed.width
            @test c[1].source.height == probed.height
            @test !hasproperty(c[1], :yadif)                     # yadif is only on the Video struct
        end
    end
end
