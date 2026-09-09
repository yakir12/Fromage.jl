# The two per-group seams in Gateway, tested directly. Both are exercised end-to-end by the gateway
# suites — that is where "a corrupt video is reported once" lives — but those tests need videos, csvs
# and a whole loader to say anything, so the seams' own contract (which rows reach the callbacks, and
# what the callbacks are handed) was only ever asserted through its consequences. It is asserted here
# instead, on a four-row DataFrame and no files at all.
module GatewayTests

using Test
using DataFrames: DataFrame
using Fromage: Fromage

const G = Fromage.Gateway

# The shape every gateway DataFrame has by the time a second-tier stage sees it: the payload columns
# plus `:issues`, one independently-mutable vector per row (`[String[] for …]`, never `fill`).
frame() = DataFrame(a = ["x", "x", "y", "z", missing],
                    b = Union{Int, Missing}[1, 1, 2, 3, 4],
                    issues = [String[] for _ in 1:5])

@testset "Gateway" begin
    @testset "detect_per_group!" begin
        @testset "one detect per group, and the key reaches both callbacks" begin
            df = frame()
            push!(df.issues[4], "flagged earlier")          # row 4 is already rejected
            calls = Threads.Atomic{Int}(0)
            G.detect_per_group!(df, [:a, :b], [:a, :b], "testing...",
                                function (k)
                                    Threads.atomic_add!(calls, 1)
                                    k.a == "x" ? "bad" : nothing
                                end,
                                # `k` is a live view onto the parent's columns, not a snapshot, so
                                # a field this callback nulls reads back as `missing` through the
                                # key. Both real frame-dumping passes are safe by construction —
                                # they build the whole message before blanking — and this one names
                                # only :a, which it does not blank.
                                (g, k, issue) -> (G.blank!(g, :b); push!.(g.issues, "$(k.a): $issue"));
                                progress = false)
            # Rows 1 and 2 share a key, so they are one detect — not two. Row 3 is the only other
            # candidate: row 4 carries an issue and row 5 has no :a, so neither is grouped at all.
            @test calls[] == 2
            # `flag!` is handed the group, so both its rows are flagged and blanked from one call.
            @test df.issues[1] == ["x: bad"] == df.issues[2]
            @test ismissing(df.b[1]) && ismissing(df.b[2])
            # A `nothing` from `detect` means clean: `flag!` is never called for that group.
            @test isempty(df.issues[3]) && df.b[3] == 2
        end

        @testset "already-flagged rows are skipped, not re-detected" begin
            df = frame()
            push!(df.issues[4], "flagged earlier")
            G.detect_per_group!(df, [:a, :b], [:a, :b], "testing...",
                                k -> "bad", (g, _, issue) -> push!.(g.issues, issue); progress = false)
            # One unusable row is one issue: the stage neither re-ran on it nor reported it twice.
            @test df.issues[4] == ["flagged earlier"]
        end

        @testset "`required` governs the drop, `groupcols` only the grouping" begin
            # The three VerifyRectifications passes group on columns they do NOT require — :yadif and
            # :blur, imputed from the probe — so a row missing one of those must still be detected,
            # in a group of its own, rather than dropped.
            df = frame()
            df.b[3] = missing
            keys_seen = Threads.Atomic{Int}(0)
            G.detect_per_group!(df, [:a], [:a, :b], "testing...",
                                k -> (Threads.atomic_add!(keys_seen, 1); "bad"),
                                (g, _, issue) -> push!.(g.issues, issue); progress = false)
            @test keys_seen[] == 3                # ("x",1), ("y",missing), ("z",3)
            @test df.issues[3] == ["bad"]         # the missing :b did not drop the row
            @test isempty(df.issues[5])           # a missing *required* column still does
        end
    end
end

end
