# The `-vf` filter string: a pure function with a spec of its own, worth pinning directly because
# the two absent-value conventions it reconciles (`missing` from a csv cell, `false`/`0` from
# VerifyRectifications) are easy to get subtly wrong. That the string reaches ffmpeg, and does
# something, is covered behaviourally in test_frame_reads.jl.

@testset "_vf filter selection" begin
    @test R._vf(missing, missing) === missing                        # no deinterlace, no blur
    @test R._vf(missing, 2.0) == "gblur=sigma=2.0"                   # blur only
    @test R._vf(true, missing) == "yadif=1"                          # deinterlace only
    @test R._vf(true, 2.0) == "yadif=1,gblur=sigma=2.0"              # both, in order
    # yadif = false means progressive footage: it must NOT deinterlace (VerifyRectifications
    # probes yadif as a Bool, so false is the common case)
    @test R._vf(false, missing) === missing
    @test R._vf(false, 2.0) == "gblur=sigma=2.0"
    # blur = 0 means no blur (VerifyRectifications' convention): no sigma-0 no-op filter
    @test R._vf(missing, 0.0) === missing
    @test R._vf(false, 0) === missing
    @test R._vf(true, 0.0) == "yadif=1"
end
