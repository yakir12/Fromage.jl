@testset "value ranges & imputation" begin
    # baseline board.mp4 has dimension (500, 376); each row overrides one field.

    @testset "center bounds" begin
        @test flagged(check([videorow(center = (0, 0))]),     1, "center cannot be smaller than 1")
        @test flagged(check([videorow(center = (600, 600))]), 1, "center cannot be larger than the dimensions")
        # only one coordinate out of bounds still trips any(.>)
        @test flagged(check([videorow(center = (600, 100))]), 1, "center cannot be larger than the dimensions")
        # center == dimension is allowed (the check is strict >)
        @test clean(check([videorow(center = (500, 376))]))
    end

    @testset "north bounds" begin
        @test flagged(check([videorow(north = (0, 0))]),     1, "north cannot be smaller than 1")
        @test flagged(check([videorow(north = (600, 600))]), 1, "north cannot be larger than the dimensions")
    end

    # A clean load returns Vector{RectificationMethod}; the scenario row is element 1, and center/north
    # now live in the shared Source struct, so inspect df[1].source.center / df[1].source.north.
    # center/north are optional and never imputed: omitted values stay missing.
    @testset "both omitted stays missing" begin
        df = check([videorow(center = missing, north = missing)])
        @test clean(df)
        @test df[1].source.center === missing
        @test df[1].source.north  === missing
    end

    @testset "north omitted with center given stays missing" begin
        df = check([videorow(north = missing)])   # center (250,180)
        @test clean(df)
        @test df[1].source.center == (250, 180)
        @test df[1].source.north  === missing
    end

    @testset "scalar field ranges" begin
        @test flagged(check([scalerow(scale = -1)]),              1, "scale must be larger than zero")
        @test flagged(check([videorow(checker_width = 0)]),        1, "checker_width must be larger than zero")
        @test flagged(check([videorow(radial_parameters = 4)]),   1, "radial_parameters must be 1, 2, or 3")
        @test flagged(check([videorow(radial_parameters = 0)]),   1, "radial_parameters must be 1, 2, or 3")
        @test flagged(check([videorow(blur = -1)]),               1, "blur must be larger than or equal to zero")
        # OpenCV's findChessboardCorners requires both pattern dimensions strictly bigger than 2,
        # so the bound is ≥ 3 — checked here rather than caught out of the detector.
        @test flagged(check([videorow(n_corners = (0, 5))]),      1, "n_corners must all be at least 3")
        @test flagged(check([videorow(n_corners = (1, 5))]),      1, "n_corners must all be at least 3")
        @test flagged(check([videorow(n_corners = (1, 1))]),      1, "n_corners must all be at least 3")
        @test flagged(check([videorow(n_corners = (2, 5))]),      1, "n_corners must all be at least 3")
        @test flagged(check([videorow(n_corners = (2, 2))]),      1, "n_corners must all be at least 3")
        @test flagged(check([videorow(temporal_step = 0)]),       1, "temporal_step must be larger than zero")
        @test flagged(check([videorow(aspect = 0)]),              1, "aspect must be larger than zero")
        @test flagged(check([videorow(aspect = -1.2)]),           1, "aspect must be larger than zero")
    end

    @testset "extrinsic timing" begin
        @test flagged(check([videorow(extrinsic = "-1")]),         1, "extrinsic must be larger than or equal to zero")
        @test flagged(check([videorow(extrinsic = "00:01:00")]),   1, "extrinsic must come before the video duration")
        # the bound is strict: seeking at exactly the duration yields no frame, so == is rejected too
        d = VRect.probe_video(joinpath(DATADIR, ART.board)).duration
        @test flagged(check([videorow(extrinsic = string(d))]), 1, "extrinsic must come before the video duration")
    end

    @testset "temporal_step too short" begin
        df = check([videorow(start = "00:00:00", stop = "00:00:01", temporal_step = 2)])
        @test flagged(df, 1, "temporal_step too short")
    end

    @testset "calibs window" begin
        # baseline video is VIDEO_DURATION (5) s.
        @test flagged(check([videorow(start = "-1", stop = "00:00:04")]),
                      1, "start must be larger than or equal to zero")
        @test flagged(check([videorow(start = "00:00:04", stop = "00:00:01")]),
                      1, "start must come before stop")
        # a window that runs past the end of the video is caught
        @test flagged(check([videorow(start = "00:00:01", stop = "00:10:00")]),
                      1, "stop can not come after video duration")
        # an inverted window must NOT also emit the misleading "temporal_step too short"
        @test !flagged(check([videorow(start = "00:00:04", stop = "00:00:01")]),
                       1, "temporal_step too short")
    end
end
