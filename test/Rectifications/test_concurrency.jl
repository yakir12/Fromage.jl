# Regression test for the global read-concurrency limiter. `_frame_at` reads each frame through
# `Base.acquire(..., READ_SEM[])`; a single global semaphore is what keeps a burst of nested
# `tmap` tasks from opening more simultaneous reads against the (CIFS) share than intended. Here
# we drive that exact mechanism under nested concurrent bursts and assert the bound is honoured —
# without spawning ffmpeg. (The former ffmpeg env-race is gone structurally: command builders now
# use the env-baked `FFMPEG.ffmpeg()` Cmd, which never mutates global `ENV`.)

@testset "read semaphore" begin

    # atomic "max seen so far" update
    function bump_peak!(peak, c)
        while true
            cur = peak[]
            c ≤ cur && return
            Threads.atomic_cas!(peak, cur, c) === cur && return
        end
    end

    @testset "bounds concurrent acquisitions at read_limit" begin
        old = R.read_limit()
        try
            for limit in (1, 3, 6)
                R.set_read_limit!(limit)
                concurrent = Threads.Atomic{Int}(0)
                peak = Threads.Atomic{Int}(0)
                # nested concurrent bursts mirror the production nested-tmap read pattern; every
                # leaf acquires the same global semaphore exactly as `_frame_at` does
                @sync for _ in 1:8
                    Threads.@spawn begin
                        @sync for _ in 1:8
                            Threads.@spawn Base.acquire(R.READ_SEM[]) do
                                c = Threads.atomic_add!(concurrent, 1) + 1
                                bump_peak!(peak, c)
                                sleep(0.01)            # hold long enough to overlap with siblings
                                Threads.atomic_sub!(concurrent, 1)
                                nothing
                            end
                        end
                    end
                end
                @test peak[] ≤ limit            # never more than `limit` reads in flight at once
                @test concurrent[] == 0         # every acquisition was released
                limit ≥ 2 && @test peak[] ≥ 2   # ...and concurrency genuinely happened (not vacuous)
            end
        finally
            R.set_read_limit!(old)              # restore the configured limit
        end
        @test R.read_limit() == old
    end

end
