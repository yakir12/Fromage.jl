# What a caller can observe about reading a frame: the right pixels, from the right timestamp,
# filtered when asked, and the same answer whether one task reads or sixty-four do. A real (tiny)
# clip is decoded by the bundled ffmpeg, so `_vf`, `_cmd`, `_read_frame` and the concurrency
# limiter are all exercised through the one entry point production uses — `_frame_at`.
#
# Deliberately says nothing about *how* the read is bounded. The limiter is an implementation
# detail (see DESIGN-HISTORY.md); what must hold is that reads under concurrency are correct.

@testset "frame reads" begin

    w, h = 64, 48

    mktempdir() do dir
        file = joinpath(dir, "testsrc.mp4")
        # testsrc: a moving pattern with a burnt-in frame counter, so consecutive timestamps are
        # genuinely different images. 3 s at 10 fps, losslessly encoded so decoding is exact.
        run(`$(R.FFMPEG.ffmpeg()) -y -hide_banner -loglevel error -f lavfi
             -i testsrc=duration=3:size=$(w)x$(h):rate=10 -c:v libx264 -crf 0 -pix_fmt yuv420p $file`)

        frame = R._frame_at(file, 1.0, missing, w, h)

        @testset "a frame comes back at the frame's shape" begin
            # `_frame_at` reshapes ffmpeg's row-major rawvideo stream and transposes it, so the
            # result is indexed (row, col) like every other image in the package.
            @test size(frame) == (h, w)
            @test eltype(frame) == UInt8
            @test 0 < sum(frame)                     # not a blank/zero decode
        end

        @testset "the timestamp is honoured" begin
            # Same file, a second apart: testsrc has moved on, so the pixels must differ. Both
            # timestamps sit well inside the clip — input-seek at end-of-stream is unreliable.
            @test R._frame_at(file, 2.0, missing, w, h) != frame
            @test R._frame_at(file, 1.0, missing, w, h) == frame   # and the same t is repeatable
        end

        @testset "the filter clause is applied" begin
            # A heavy gblur must visibly smooth testsrc's hard edges. Comparing spread rather than
            # pixels keeps this about the filter reaching ffmpeg, not about ffmpeg's blur kernel.
            blurred = R._frame_at(file, 1.0, R._vf(missing, 8.0), w, h)
            spread(a) = maximum(Float64.(a)) - minimum(Float64.(a))
            @test spread(blurred) < spread(frame)
        end

        @testset "concurrent reads are correct" begin
            # The production read pattern is nested `tmap`s over a network share; here, nested
            # spawns over the same file. Every task must get the byte-identical frame a lone
            # reader gets — no interleaved decode, no torn buffer, no env race between builders.
            # These once ran under a global semaphore that capped simultaneous opens; it was
            # measured to prevent nothing (5,371 reads at concurrency 1 through 48, zero
            # failures) and removed, so the reads here are unbounded, as in production.
            results = Vector{Matrix{UInt8}}(undef, 64)
            @sync for i in 1:8
                Threads.@spawn @sync for j in 1:8
                    Threads.@spawn results[(i - 1) * 8 + j] = R._frame_at(file, 1.0, missing, w, h)
                end
            end
            @test all(==(frame), results)
        end

        @testset "reading leaves the process environment alone" begin
            # The command builders interpolate the env-baked `FFMPEG.ffmpeg()` Cmd, which carries
            # its PATH/LD_LIBRARY_PATH in the `Cmd` rather than exporting them. Nothing above may
            # have mutated global `ENV` — that is what makes the reads above safe to run at once.
            before = Dict(ENV)
            R._frame_at(file, 1.0, R._vf(true, 2.0), w, h)
            @test Dict(ENV) == before
        end
    end

end
