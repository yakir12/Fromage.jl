# Build-time precompilation scaffolding, kept in its own file so it can be excluded from coverage
# (see codecov.yml): these lines run during precompilation, which the coverage run does not
# instrument, so they can never be hit by the test suite no matter how well the package is tested.

# Precompile the parse → verify → report pipeline at build time. The bulk of first-call latency is the
# DataFrames/DataFramesMeta/Chain macro machinery (column-typed `@transform!`/`@chain`/`subset`/`verify!`
# specializations), which a single `load_rectifications` run compiles. The workload CSV points at
# nonexistent files (one row per type), so the run exercises the full pipeline for all three types but
# bails before any ffprobe/matread/corner detection — no bundled media needed, fast deterministic
# precompile. (The video-read/corner-detection paths are left to compile on first real use.)
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
                # Deliberately broad: precompilation must not fail because the workload did. An
                # interrupt is the exception — Ctrl-C during precompile should stop it, not be
                # absorbed here.
                e isa InterruptException && rethrow()
            end
        end
    end
end
