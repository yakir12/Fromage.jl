# The csv rung (#303): the same simulated video and snapped gauge as the builder rung, entering
# Fromage through rectifications.csv → verify → load_rectifications → build_rectification.

"""
    measure_csv(rig_name, cam::Camera, poses, file, results_dir, inputs) -> Vector{Row}

Measure the rig through the CSV gateway. The input files and gateway issue output live below the
simulation run's `results_dir`; the built maps are obtained from the verified CSV methods, while
the fitted camera models are retained only to report the same intrinsic quantities as the builder
rung.
"""
function measure_csv(rig_name, cam::Camera, poses, file, results_dir, inputs)
    return measure_rung(rig_name, "csv", cam, poses, file, inputs) do g, detected
        csv_fits(cam, g, poses, file, detected, results_dir)
    end
end

function csv_fits(cam::Camera, g::Gauge, poses, file, detected, results_dir)
    inputs_dir = joinpath(results_dir, "inputs")
    mkpath(inputs_dir)
    data_path = mktempdir(inputs_dir)
    gateway_results = joinpath(results_dir, "gateway")
    video = joinpath(data_path, "board.mp4")
    symlink(realpath(file), video)
    write_csv_inputs(data_path, poses, g)

    # `verify` is the public gateway invocation; `load_rectifications` is the internal route whose
    # verified methods are then built so the report measures exactly what the CSV path produced.
    Fromage.verify(data_path; results_dir = gateway_results)
    methods = Fromage.VerifyRectifications.load_rectifications(
        data_path, joinpath(data_path, "rectifications.csv");
        defaults = (;), results_dir = gateway_results, progress = false,
    )
    built = Dict(c.rectification_id => attempt(() -> Fromage.build_rectification(c)) for c in methods)

    calibration = filter(is_found, detected[1:(end - 1)])
    direct = builder_fits(cam, g, file, calibration, detected[end])
    return (
        from_checkerboard = (rect = built["checkerboard"], model = direct.from_checkerboard.model),
        from_extrinsic = (rect = built["extrinsic"], model = direct.from_extrinsic.model),
    )
end

function write_csv_inputs(data_path, poses, g::Gauge)
    extrinsic = lastindex(poses) - 1
    intrinsic_stop = extrinsic - 1
    center = Tuple(round.(Int, g.center))
    north = Tuple(round.(Int, g.north))
    point(p) = "\"($(p[1]), $(p[2]))\""
    open(joinpath(data_path, "rectifications.csv"), "w") do io
        println(io, "rectification_id,file,extrinsic,intrinsic_start,intrinsic_stop,temporal_step,n_corners,checker_width,center,north")
        println(io, "checkerboard,board.mp4,$extrinsic,0,$intrinsic_stop,1,,,$(point(center)),$(point(north))")
        println(io, "extrinsic,board.mp4,$extrinsic,,,,,,$(point(center)),$(point(north))")
    end
    open(joinpath(data_path, "runs.csv"), "w") do io
        println(io, "run_id,rectification_id,file")
        println(io, "r_checkerboard,checkerboard,board.mp4")
        println(io, "r_extrinsic,extrinsic,board.mp4")
    end
    return data_path
end
