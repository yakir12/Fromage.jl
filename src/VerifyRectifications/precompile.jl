# Build-time precompilation scaffolding, in its own file so it can be excluded from coverage (see
# codecov.yml): it runs during precompilation, which the coverage run does not instrument.

# Precompile the parse → verify → report pipeline. The bulk of first-call latency is the
# DataFrames machinery (column-typed `subset`/`groupby`/`verify!`
# specializations) a single `load_rectifications` run
# compiles. The workload CSV points at nonexistent files, one row per type, so the run exercises the
# full pipeline for every type but bails before any ffprobe/matread/corner detection.
@setup_workload begin
    dir = mktempdir()
    csv = joinpath(dir, "precompile.csv")
    open(csv, "w") do io
        # Minimal header (other columns are back-filled by parse_row); one row per type so all three
        # parse branches and the type-specific verifications compile. All point at a nonexistent file.
        println(io, "calibration_id,file,matlab_file,type,extrinsic,extrinsic_index,scale")
        println(io, "v,nope.mp4,,video,1,,")
        println(io, "m,nope.mp4,nope.mat,matlab,1,1,")
        println(io, "s,nope.mp4,,only_scale,1,,9.5")
        println(io, "a,nope.mp4,,apriltag,1,,")
    end
    @compile_workload begin
        redirect_stdout(devnull) do
            try
                load_rectifications(dir, csv; strict = false)
            catch e
                # Deliberately broad: precompilation must not fail because the workload did. Ctrl-C
                # during precompile should still stop it.
                e isa InterruptException && rethrow()
            end
        end
    end
end
