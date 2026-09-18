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
    function judged_row(r, floor)
        reference = merge(r, (; rig = "baseline", value = floor))
        return only(CRS.judged([r], CRS.Floors([reference], [reference])))
    end

    @testset "total map: both strict bounds, every split and builder" begin
        for builder in ("from_checkerboard", "from_extrinsic"), split in ("arena", "on board", "off board", "Procrustes")
            for (statistic, tolerance) in (("RMS", 1.0), ("max", 3.0))
                r = measurement(; builder, split, statistic)
                # Above the ratio bound alone, or the tolerance alone, is not serious.
                for (value, floor, expected) in (
                        (tolerance, tolerance / 4, "ok"),
                        (2tolerance, tolerance, "ok"),
                        (3tolerance, tolerance, "ok"),
                        (4tolerance, tolerance, "serious"),
                        (-4tolerance, tolerance, "serious"),
                    )
                    got = judged_row(merge(r, (; value)), floor)
                    @test got.verdict == expected
                    @test got.family == "total" && got.tolerance == tolerance
                    @test got.floor == floor
                end
            end
        end
    end

    @testset "dot separation is signed, in mm" begin
        for (value, floor, expected) in ((1.0, 0.2, "ok"), (-1.0, 0.2, "ok"), (3.0, 1.0, "ok"), (-2.0, 0.5, "serious"))
            got = judged_row(measurement(; quantity = "dot separation", split = "centroids", statistic = "error", value), floor)
            @test got.verdict == expected
            @test got.family == "total" && got.tolerance == 1.0
        end
    end

    @testset "corners and intrinsics are diagnostic only" begin
        for (quantity, statistic, unit) in (("corners", "RMS", "stored px"), ("corners", "max", "display px"), ("intrinsics", "error", ""))
            for (value, expected) in ((0.03, "ok"), (0.04, "diagnostic"), (-100.0, "diagnostic"))
                got = judged_row(measurement(; quantity, statistic, unit, value), 0.01)
                @test got.verdict == expected
                @test got.family == "total" && ismissing(got.tolerance)
            end
        end
    end

    @testset "model map: both strict bounds" begin
        for builder in ("from_checkerboard", "from_extrinsic"), statistic in ("RMS", "max"), split in ("arena", "on board", "off board", "Procrustes")
            for (value, floor, expected) in ((0.1, 0.003, "ok"), (0.2, 0.02, "ok"), (0.11, 0.003, "serious"), (0.2, 0.03, "ok"))
                got = judged_row(measurement(; builder, statistic, split, section = "control", value), floor)
                @test got.verdict == expected
                @test got.family == "model" && got.tolerance == 0.1
            end
        end
    end

    @testset "missed detection and absent map" begin
        for (value, expected) in ((0.0, "serious"), (1.0, "ok"))
            got = judged_row(measurement(; builder = missing, quantity = "detection", statistic = "detected", split = "flat", value, unit = "frame"), missing)
            @test got.verdict == expected && got.family == "total"
            @test all(ismissing, (got.floor, got.ratio, got.tolerance))
        end
        got = judged_row(measurement(; value = missing, status = "not detected"), 0.1)
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
            got = judged_row(r, 0.001)
            @test got.verdict == "n/a"
            @test isequal(CRS.Row(got), r)
        end
    end

    @testset "zero and missing floors" begin
        zero = judged_row(measurement(; value = 0.0), 0.0)
        @test zero.ratio == 0.0 && zero.verdict == "ok"
        nonzero = judged_row(measurement(), 0.0)
        @test nonzero.ratio == Inf && nonzero.verdict == "serious"
        absent = judged_row(measurement(), missing)
        @test ismissing(absent.floor) && ismissing(absent.ratio) && absent.verdict == "n/a"
    end

    @testset "baseline floors: maxima, signs, and control seeds" begin
        replicates = [measurement(; rig = "baseline, replicate $seed", value = -seed / 10) for seed in 1:10]
        append!(
            replicates, [
                measurement(; value = missing),
                measurement(; builder = "from_extrinsic", value = 9.0),
                measurement(; statistic = "max", value = 4.0),
                measurement(; split = "off board", value = 2.0),
                measurement(; builder = missing, quantity = "corners", value = 0.1, unit = "stored px"),
            ]
        )
        seeds = [[measurement(; rig = "baseline", builder = "from_extrinsic", section = "control", value = seed / 100)] for seed in 1:10]
        baseline = [CRS.aggregate_seeds(seeds); measurement(; rig = "baseline", section = "control", value = 0.003)]
        floors = CRS.Floors(replicates, baseline)
        cases = [
            measurement(; value = 4.0),
            measurement(; builder = "from_extrinsic", value = 18.0),
            measurement(; statistic = "max", value = 8.0),
            measurement(; split = "off board", value = 4.0),
            measurement(; builder = missing, quantity = "corners", value = 0.4, unit = "display px"),
            measurement(; section = "control", value = 0.12),
            measurement(; builder = "from_extrinsic", section = "control", aggregate = "median", value = 0.8),
        ]
        got = CRS.judged(cases, floors)
        @test getproperty.(got, :floor) == [1.0, 9.0, 4.0, 2.0, 0.1, 0.003, 0.1]
        @test getproperty.(got, :ratio) ≈ [4.0, 2.0, 2.0, 2.0, 4.0, 40.0, 8.0]
        @test getproperty.(got, :verdict) == ["serious", "ok", "ok", "ok", "diagnostic", "serious", "ok"]
    end
end
