@testset "summary keeps the rungs separate" begin
    rows = CRS.Row[]
    for (rung, found) in (("builders", 2), ("csv", 1))
        ctx = (; rig = "baseline", rung, builder = missing, section = "fromage")
        for (split, value) in (("waved", 1), ("flat", found - 1), ("all", found))
            push!(rows, CRS.row(ctx; quantity = "detection", split, statistic = "detected", value, unit = "frames"))
        end
        for builder in ("from_checkerboard", "from_extrinsic")
            push!(rows, CRS.row((; ctx..., builder); quantity = "dot separation", statistic = "error", value = 0, unit = "mm"))
        end
    end
    report = [merge(r, (; verdict = "ok")) for r in rows]
    printed = sprint(CRS.print_summary, report)
    @test occursin("baseline / builders", printed)
    @test occursin("baseline / csv", printed)
    @test occursin("frames detected: 2 of 2", printed)
    @test occursin("frames detected: 1 of 2", printed)
    @test occursin("missed: flat", printed)
    @test occursin("serious rows: none", printed)
end
