# `Gateway.detect_per_group!`, tested directly. It is exercised end-to-end by the VerifyRectifications
# suite — that is where "a corrupt video is reported once" lives — but those tests need videos, csvs
# and a whole loader to say anything, so the seam's own contract (which rows reach the callbacks, and
# what the callbacks are handed) was only ever asserted through its consequences. It is asserted here
# instead, on a five-row DataFrame and no files at all. Its sibling `read_per_file!` has no direct
# tests yet; the gateway suites are still the only thing holding it.
module GatewayTests

using Test
using DataFrames: DataFrame
using Fromage: Fromage

const G = Fromage.Gateway

# The shape every gateway DataFrame has by the time a second-tier stage sees it: the payload columns
# plus `:issues`, one independently-mutable vector per row (`[String[] for …]`, never `fill`).
frame() = DataFrame(
    a = ["x", "x", "y", "z", missing],
    b = Union{Int, Missing}[1, 1, 2, 3, 4],
    issues = [String[] for _ in 1:5]
)

@testset "Gateway" begin
    @testset "detect_per_group!" begin
        @testset "one detect per group, and the key reaches both callbacks" begin
            df = frame()
            push!(df.issues[4], "flagged earlier")          # row 4 is already rejected
            calls = Threads.Atomic{Int}(0)
            G.detect_per_group!(
                df, [:a, :b], [:a, :b], "testing...",
                function (k)
                    Threads.atomic_add!(calls, 1)
                    k.a == "x" ? "bad" : nothing
                end,
                # This one names only :a, which it does not blank — the live-view
                # hazard that makes that matter has a testset of its own below.
                (g, k, issue) -> (G.blank!(g, :b); push!.(g.issues, "$(k.a): $issue"));
                progress = false
            )
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
            calls = Threads.Atomic{Int}(0)
            G.detect_per_group!(
                df, [:a, :b], [:a, :b], "testing...",
                k -> (Threads.atomic_add!(calls, 1); "bad"),
                (g, _, issue) -> push!.(g.issues, issue); progress = false
            )
            # Not re-detected: only ("x",1) and ("y",2) are grouped at all — row 4 carries an issue
            # and row 5 has no :a. And not re-reported: one unusable row stays one issue.
            @test calls[] == 2
            @test df.issues[4] == ["flagged earlier"]
        end

        @testset "a group key is a live view onto the parent, not a snapshot" begin
            # The hazard `flag_extrinsic!` is built around: it saves the frame and builds its whole
            # message BEFORE `blank!`, because a key field read after the blank is `missing`. Pinned
            # here rather than left to a comment — reorder those two lines and this is what fails.
            df = frame()
            before, after = Ref{Any}(), Ref{Any}()
            G.detect_per_group!(
                df, [:a, :b], [:a, :b], "testing...",
                k -> k.a == "x" ? "bad" : nothing,
                function (g, k, issue)
                    before[] = k.b
                    G.blank!(g, :b)
                    after[] = k.b
                end; progress = false
            )
            @test before[] == 1
            @test ismissing(after[])
        end

        @testset "a required column that is not grouped on is refused" begin
            # `detect` is handed the KEY, so a column it needs that is not in the key is a column it
            # cannot read. The containment also catches the transposition the two adjacent
            # `Vector{Symbol}` arguments invite: swapping them would otherwise run, and merge rows
            # that differ on a required column into one detect.
            @test_throws ArgumentError G.detect_per_group!(
                frame(), [:a, :b], [:a], "testing...",
                k -> "bad", (g, _, i) -> nothing; progress = false
            )
        end

        @testset "`required` governs the drop, `groupcols` only the grouping" begin
            # The three VerifyRectifications passes group on columns they do NOT require — :yadif and
            # :blur, imputed from the probe — so a row missing one of those must still be detected,
            # in a group of its own, rather than dropped.
            df = frame()
            df.b[3] = missing
            keys_seen = Threads.Atomic{Int}(0)
            G.detect_per_group!(
                df, [:a], [:a, :b], "testing...",
                k -> (Threads.atomic_add!(keys_seen, 1); "bad"),
                (g, _, issue) -> push!.(g.issues, issue); progress = false
            )
            @test keys_seen[] == 3                # ("x",1), ("y",missing), ("z",3)
            @test df.issues[3] == ["bad"]         # the missing :b did not drop the row
            @test isempty(df.issues[5])           # a missing *required* column still does
        end
    end
end

end
