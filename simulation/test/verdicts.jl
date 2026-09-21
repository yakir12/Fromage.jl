# The table in #296, exercised on report rows rather than individual rule implementations.
@testset "verdict rules" begin
    function measurement(;
            rig = "variant", builder = "from_checkerboard", section = "fromage",
            quantity = "map", split = "arena", statistic = "RMS", value = 2.0,
            unit = "mm", aggregate = missing, status = "ok"
        )
        ctx = (; rig, rung = "builders", builder, section)
        return CRS.row(ctx; quantity, split, statistic, value, unit, aggregate, status)
    end
    # `r` judged against a baseline at `level` whose replicates spread by `floor` (#312)
    function judged_row(r, level, floor)
        levels = Dict(CRS.floor_key(r) => (; level, floor))
        return only(CRS.judged([r], CRS.Floors(levels, levels)))
    end

    @testset "total map: both strict bounds, every split and builder" begin
        for builder in ("from_checkerboard", "from_extrinsic"), split in ("arena", "on board", "off board", "Procrustes")
            for (statistic, tolerance) in (("RMS", 1.0), ("max", 3.0))
                r = measurement(; builder, split, statistic)
                # Above the spread bound alone, or the tolerance alone, is not serious.
                for (value, level, floor, expected) in (
                        (tolerance, 0.0, tolerance / 4, "ok"),
                        (2tolerance, tolerance, tolerance / 2, "ok"),
                        (4tolerance, tolerance, tolerance, "ok"),
                        (4tolerance, 2tolerance, tolerance / 2, "serious"),
                        (-4tolerance, 2tolerance, tolerance / 2, "serious"),
                        # a systematic baseline above the tolerance is not itself serious (#312)
                        (3tolerance, 3tolerance, tolerance / 10, "ok"),
                        # nor is a variant better than the baseline by many spreads
                        (2tolerance, 5tolerance, tolerance / 10, "ok"),
                    )
                    got = judged_row(merge(r, (; value)), level, floor)
                    @test got.verdict == expected
                    @test got.family == "total" && got.tolerance == tolerance
                    @test got.level == level && got.floor == floor
                    @test got.ratio ≈ (abs(value) - level) / floor
                end
            end
        end
    end

    @testset "dot separation is signed, in mm" begin
        for (value, expected) in ((1.0, "ok"), (-1.0, "ok"), (1.5, "serious"), (-2.0, "serious"))
            got = judged_row(measurement(; quantity = "dot separation", split = "centroids", statistic = "error", value), 0.2, 0.1)
            @test got.verdict == expected
            @test got.family == "total" && got.tolerance == 1.0
        end
    end

    @testset "corners and intrinsics are diagnostic only" begin
        for (quantity, statistic, unit) in (("corners", "RMS", "stored px"), ("corners", "max", "display px"), ("intrinsics", "error", ""))
            for (value, expected) in ((0.03, "ok"), (0.04, "diagnostic"), (-100.0, "diagnostic"))
                got = judged_row(measurement(; quantity, statistic, unit, value), 0.0, 0.01)
                @test got.verdict == expected
                @test got.family == "total" && ismissing(got.tolerance)
            end
        end
    end

    @testset "model map: both strict bounds" begin
        for builder in ("from_checkerboard", "from_extrinsic"), statistic in ("RMS", "max"), split in ("arena", "on board", "off board", "Procrustes")
            for (value, level, floor, expected) in ((0.1, 0.0, 0.003, "ok"), (0.2, 0.0, 0.02, "ok"), (0.11, 0.003, 0.003, "serious"), (0.2, 0.003, 0.03, "ok"))
                got = judged_row(measurement(; builder, statistic, split, section = "control", value), level, floor)
                @test got.verdict == expected
                @test got.family == "model" && got.tolerance == 0.1
            end
        end
    end

    # #312's measurement: from_extrinsic's control is ~2.7 mm off at the baseline, a builder
    # limitation, and spreads by ~0.23 mm over the replicates and seeds. Judged against that level,
    # k1 = -0.3's 26 mm is serious; judged against 10× the level, as before, it read ok.
    @testset "a systematic baseline is a level, not a floor" begin
        r(value) = measurement(; builder = "from_extrinsic", section = "control", aggregate = "median", value)
        @test judged_row(r(26.19), 2.67, 0.23).verdict == "serious"
        @test judged_row(r(13.21), 2.67, 0.23).verdict == "serious"
        @test judged_row(r(3.74), 2.67, 0.23).verdict == "ok"
        @test judged_row(r(2.67), 2.67, 0.23).verdict == "ok"
    end

    @testset "missed detection and absent map" begin
        for (value, expected) in ((0.0, "serious"), (1.0, "ok"))
            r = measurement(; builder = missing, quantity = "detection", statistic = "detected", split = "flat", value, unit = "frame")
            got = only(CRS.judged([r], CRS.Floors(CRS.Row[], CRS.Row[])))
            @test got.verdict == expected && got.family == "total"
            @test all(ismissing, (got.level, got.floor, got.ratio, got.tolerance))
        end
        got = judged_row(measurement(; value = missing, status = "not detected"), 0.1, 0.01)
        @test got.verdict == "n/a" && ismissing(got.ratio)
        @test got.status == "not detected" && got.tolerance == 1.0
    end

    @testset "unjudged quantities retain their rows" begin
        for r in (
                measurement(; statistic = "p95", value = 100.0),
                measurement(; quantity = "corners", statistic = "p95", value = 100.0),
                measurement(; quantity = "intrinsics", statistic = "fitted"),
                measurement(; quantity = "detection", statistic = "detected", split = "all", value = 27.0),
                measurement(; section = "control", aggregate = "min"),
                measurement(; section = "control", aggregate = "max"),
                measurement(; section = "self-check"),
            )
            got = judged_row(r, 0.001, 0.001)
            @test got.verdict == "n/a"
            @test isequal(CRS.Row(got), r)
        end
    end

    @testset "zero and missing floors" begin
        zero = judged_row(measurement(; value = 0.0), 0.0, 0.0)
        @test zero.ratio == 0.0 && zero.verdict == "ok"
        at_level = judged_row(measurement(), 2.0, 0.0)
        @test at_level.ratio == 0.0 && at_level.verdict == "ok"
        below = judged_row(measurement(), 3.0, 0.0)
        @test below.ratio == -Inf && below.verdict == "ok"
        above = judged_row(measurement(), 0.0, 0.0)
        @test above.ratio == Inf && above.verdict == "serious"
        absent = only(CRS.judged([measurement()], CRS.Floors(CRS.Row[], CRS.Row[])))
        @test ismissing(absent.level) && ismissing(absent.floor) && ismissing(absent.ratio) && absent.verdict == "n/a"
    end

    @testset "baseline levels and floors: medians, spreads, signs, and control seeds" begin
        replicates = [measurement(; rig = "baseline, replicate $seed", value = -seed / 10) for seed in 1:10]
        append!(
            replicates, [
                measurement(; value = missing),
                measurement(; statistic = "max", value = 4.0),
                # the replicates' own controls join the baseline's
                measurement(; section = "control", value = 0.004),
            ]
        )
        seeds = [[measurement(; rig = "baseline", builder = "from_extrinsic", section = "control", value = seed / 100)] for seed in 1:10]
        baseline = [CRS.aggregate_seeds(seeds); measurement(; rig = "baseline", section = "control", value = 0.003)]
        floors = CRS.Floors(replicates, baseline)
        cases = [
            measurement(; value = 4.0),
            measurement(; value = 3.0),
            measurement(; statistic = "max", value = 4.0),
            measurement(; statistic = "max", value = 8.0),
            measurement(; section = "control", value = 0.12),
            measurement(; builder = "from_extrinsic", section = "control", aggregate = "median", value = 0.8),
            measurement(; builder = "from_extrinsic", section = "control", aggregate = "median", value = 1.0),
        ]
        got = CRS.judged(cases, floors)
        # magnitudes 0.1…1.0; a single value; 0.003 and 0.004; the seeds' min, median and max
        @test getproperty.(got, :level) ≈ [0.55, 0.55, 4.0, 4.0, 0.0035, 0.055, 0.055]
        @test getproperty.(got, :floor) ≈ [0.9, 0.9, 0.0, 0.0, 0.001, 0.09, 0.09]
        @test getproperty.(got, :verdict) == ["serious", "ok", "ok", "serious", "serious", "ok", "serious"]
    end

    # #313: the replicates are at `sar` 1 and emit no display-px row, so a display-px row has no
    # floor, rather than borrowing the stored-px one beside it
    @testset "a floor is shared only by rows of one unit" begin
        stored = measurement(; rig = "sar_2_1", builder = missing, quantity = "corners", split = "all frames", value = 0.12, unit = "stored px")
        display = merge(stored, (; value = 0.24, unit = "display px"))
        @test !isequal(CRS.floor_key(stored), CRS.floor_key(display))
        replicates = [merge(stored, (; rig = "baseline, replicate $seed", value)) for (seed, value) in ((1, 0.1), (2, 0.14))]
        floors = CRS.Floors(replicates, CRS.Row[])
        s, d = CRS.judged([stored, display], floors)
        @test s.level ≈ 0.12 && s.floor ≈ 0.04 && s.verdict == "ok"
        @test s.ratio ≈ 0 atol = 1.0e-12
        @test ismissing(d.floor) && ismissing(d.ratio) && d.verdict == "n/a"
        @test d.value == 0.24 && d.unit == "display px"
    end
end
