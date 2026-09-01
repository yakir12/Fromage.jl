# Unit tests for the shared CSV-cell machinery (Fromage.Parsing), used by both gateways — which
# cover parseto!/resolve_defaults end to end through their csv scenarios; here we pin the
# low-level parsers once instead of once per gateway.
module ParsingTests

using Test
using Fromage: Fromage

const P = Fromage.Parsing

# A value whose conversion fails with something other than the two "rejected value" exceptions —
# used to pin that such an error propagates instead of being relabelled as a bad default.
struct Boom end
Base.convert(::Type{Int}, ::Boom) = error("boom")

@testset "Parsing (shared cell machinery)" begin
    @testset "MyTemporal: seconds vs HH:MM:SS precedence" begin
        @test P.mytryparse(P.MyTemporal, "1.5")      == 1.5    # float path taken before Time
        @test P.mytryparse(P.MyTemporal, "90")       == 90.0
        @test P.mytryparse(P.MyTemporal, "00:01:30") == 90.0   # clock converted to seconds
        @test P.mytryparse(P.MyTemporal, "garbage")  === nothing
    end

    # A stray space around a hand-edited cell must not decide whether it parses. Base's Float64
    # parser skips surrounding whitespace and its Time parser does not, so the clock form used to
    # be rejected as "wrong format" while the identical value written as a number was accepted.
    @testset "MyTemporal: surrounding whitespace is trimmed" begin
        @test P.mytryparse(P.MyTemporal, " 00:01:30 ") == 90.0   # the regression
        @test P.mytryparse(P.MyTemporal, "\t00:01:30\n") == 90.0
        @test P.mytryparse(P.MyTemporal, " 12.5 ")     == 12.5
        @test P.mytryparse(P.MyTemporal, " 9 ")        == 9.0
        @test P.mytryparse(P.MyTemporal, "  ")         === nothing   # blank stays absent, not 0
        @test P.mytryparse(P.MyTemporal, " 00:0x:30 ") === nothing   # trimming does not rescue junk
    end

    @testset "NTuple{2,Int}: accepted forms and rejects" begin
        @test P.mytryparse(NTuple{2, Int}, "(7,10)")      == (7, 10)
        @test P.mytryparse(NTuple{2, Int}, "[250, 1]")    == (250, 1)   # bracket form
        @test P.mytryparse(NTuple{2, Int}, "250,1")       == (250, 1)   # bare form
        @test P.mytryparse(NTuple{2, Int}, "  250 , 1  ") == (250, 1)   # surrounding whitespace
        @test P.mytryparse(NTuple{2, Int}, "(-5, 5)")     == (-5, 5)    # negatives parse; the range checks flag them
        @test P.mytryparse(NTuple{2, Int}, "1,2,3")       === nothing   # not a 2-tuple
        @test P.mytryparse(NTuple{2, Int}, "abc")         === nothing
        @test P.mytryparse(NTuple{2, Int}, "(10000000000000000000,1)") === nothing  # >Int64 overflows -> nothing, not a throw
    end

    # `parseto!` and `set!` are the machinery every csv cell goes through, and they had no direct
    # test: their behaviour was covered only through the ~20 "wrong X format" / "X is missing"
    # message assertions in the two gateway suites. Those pin the messages; these pin the effects.
    @testset "parseto!: what lands in the dict, and what lands in :issues" begin
        fresh() = Dict{Symbol, Any}(:issues => String[])

        # a filled, parseable cell: the value, and nothing reported
        d = fresh(); P.parseto!(d, (; n = "42"), :n, Int)
        @test d[:n] == 42
        @test isempty(d[:issues])

        # a filled cell that will not parse: the field is NULLED, and the issue names the column.
        # The nulling is what stops later checks piling on the same row.
        d = fresh(); P.parseto!(d, (; n = "not_a_number"), :n, Int)
        @test d[:n] === missing
        @test d[:issues] == ["wrong n format"]

        # absent, with no default: reported as missing
        d = fresh(); P.parseto!(d, (;), :n, Int)
        @test d[:n] === missing
        @test d[:issues] == ["n is missing"]

        # absent, WITH a default: the default is taken and nothing is reported — this is the
        # optional-field path, and it must not add an issue
        d = fresh(); P.parseto!(d, (;), :n, Int, 7)
        @test d[:n] == 7
        @test isempty(d[:issues])

        # a present-but-blank cell is an absent cell (DESIGN-HISTORY: "Cells are trimmed, and a
        # blank cell is an absent cell"), so it takes the default rather than becoming ""
        d = fresh(); P.parseto!(d, (; s = "   "), :s, String, "fallback")
        @test d[:s] == "fallback"
        @test isempty(d[:issues])
    end

    @testset "set!: a value passes through, `nothing` nulls and reports" begin
        d = Dict{Symbol, Any}(:issues => String[])
        P.set!(d, 5, :a, "unused when the value is there")
        @test d[:a] == 5
        @test isempty(d[:issues])

        P.set!(d, nothing, :b, "b went wrong")
        @test d[:b] === missing            # nulled, so later checks skip this field
        @test d[:issues] == ["b went wrong"]
    end

    @testset "resolve_defaults: rejected values vs. genuine errors" begin
        # A miniature whitelist standing in for a gateway's DEFAULTS/DEFAULT_TYPES pair.
        defaults = (; a = 1.0, n = 2, flag = true)
        types    = (; a = Float64, n = Int, flag = Bool)
        resolve(o) = P.resolve_defaults(o, defaults, types, "test")

        @test resolve((;)) == defaults                          # no overrides: untouched
        @test resolve((; a = 3)).a === 3.0                      # converted to the column's type
        @test resolve((; n = 5)) == (; a = 1.0, n = 5, flag = true)

        # Not on the whitelist at all -> fails fast, naming the settable keys.
        @test_throws ArgumentError resolve((; nope = 1))

        # The two ways a value can be rejected, both relabelled as ArgumentError:
        @test_throws ArgumentError resolve((; flag = "yes"))    # MethodError: no such conversion
        @test_throws ArgumentError resolve((; n = 1.5))         # InexactError: would lose information
        @test_throws ArgumentError resolve((; flag = 2))        # InexactError: 2 is not a Bool

        # ...and an error that is NOT a rejected value must propagate unchanged rather than be
        # reported to the user as "must be convertible to". Boom is our own type, so extending
        # convert on it is not piracy.
        @test_throws ErrorException resolve((; n = Boom()))
    end

    @testset "String: trimmed and materialized" begin
        @test P.mytryparse(String, "  video ") == "video"
        @test P.mytryparse(String, SubString(" x ", 1)) isa String   # a real String, not a SubString
    end
end

end
