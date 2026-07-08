# Unit tests for the shared CSV-cell machinery (Fromage.Parsing), used by both gateways — which
# cover parseto!/resolve_defaults end to end through their csv scenarios; here we pin the
# low-level parsers once instead of once per gateway.
module ParsingTests

using Test
using Fromage: Fromage

const P = Fromage.Parsing

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

    @testset "String: trimmed and materialized" begin
        @test P.mytryparse(String, "  video ") == "video"
        @test P.mytryparse(String, SubString(" x ", 1)) isa String   # a real String, not a SubString
    end
end

end
