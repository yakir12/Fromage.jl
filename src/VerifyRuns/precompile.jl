# Build-time precompilation scaffolding, in its own file so it can be excluded from coverage (see
# codecov.yml): it runs during precompilation, which the coverage run does not instrument.

# Precompile the parse → verify → report pipeline. The bulk of first-call latency is the
# DataFrames machinery (column-typed `subset`/`groupby`/`verify!` specializations) a single
# `load_runs` run compiles. The workload CSV points at a nonexistent file, so the run exercises the
# full parse + verification path but bails before any ffprobe — no bundled media, fast and
# deterministic.
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
                # Deliberately broad: precompilation must not fail because the workload did. Ctrl-C
                # during precompile should still stop it.
                e isa InterruptException && rethrow()
            end
        end
    end
end
