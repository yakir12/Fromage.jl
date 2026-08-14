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
