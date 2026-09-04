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
        # Minimal header (other columns are back-filled by parse_row); one row per type so all four
        # parse branches and the type-specific verifications compile. All point at a nonexistent file.
        println(io, "calibration_id,file,matlab_file,type,extrinsic,extrinsic_index,pixel_width")
        println(io, "v,nope.mp4,,checkerboard,1,,")
        println(io, "m,nope.mp4,nope.mat,matlab,1,1,")
        println(io, "s,nope.mp4,,uniform,1,,9.5")
        println(io, "a,nope.mp4,,apriltag,1,,")
    end
    @compile_workload begin
        # `progress = false` silences the meters, which draw on stderr; the redirect silences the
        # issues report, which is a genuine println to stdout. Neither belongs in precompile output.
        redirect_stdout(devnull) do
            try
                check_rectifications(dir, csv; progress = false)
            catch e
                # Deliberately broad: precompilation must not fail because the workload did. Ctrl-C
                # during precompile should still stop it.
                e isa InterruptException && rethrow()
            end
        end
    end
end
