# Build-time precompilation scaffolding, kept in its own file so it can be excluded from coverage
# (see codecov.yml): these lines run during precompilation, which the coverage run does not
# instrument, so they can never be hit by the test suite no matter how well the package is tested.

# Precompile the parse → verify → report pipeline at build time. The bulk of first-call latency is the
# DataFrames/DataFramesMeta/Chain macro machinery a single `load_runs` run compiles. The workload CSV
# points at a nonexistent file, so the run exercises the full parse + verification path but bails (file
# does not exist) before any ffprobe — no bundled media needed, fast and deterministic. (The video-read
# path is left to compile on first real use.)
@setup_workload begin
    dir = mktempdir()
    csv = joinpath(dir, "precompile.csv")
    open(csv, "w") do io
        println(io, "run_id,calibration_id,file,start,stop")
        println(io, "r,c,nope.mp4,0,5")
    end
    @compile_workload begin
        redirect_stdout(devnull) do
            try
                load_runs(dir, csv; strict = false)
            catch e
                # Deliberately broad: precompilation must not fail because the workload did. An
                # interrupt is the exception — Ctrl-C during precompile should stop it, not be
                # absorbed here.
                e isa InterruptException && rethrow()
            end
        end
    end
end
