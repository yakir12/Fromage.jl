function seek_snap(path, vid, t, name = t)
    seek(vid, t)
    img = read(vid)
    save(joinpath(path, "$name.png"), img)
end

function calib(file, start, stop, extrinsic, checker_size, n_corners, temporal_step)
    vid = openvideo(file, target_format=VideoIO.AV_PIX_FMT_GRAY8)
    read(vid)
    t₀ = gettime(vid)
    start += t₀
    stop += t₀
    extrinsic += t₀
    ts = range(start, stop, step = temporal_step)
    mktempdir() do path
        fldr = basename(path)
        foreach(t -> seek_snap(path, vid, t), ts)
        seek_snap(path, vid, extrinsic, "extrinsic")
        files = readdir(path; join=true)
        aspect = VideoIO.aspect_ratio(vid)
        try
            c, ϵ = fit(files, n_corners, checker_size; aspect)
            if isnothing(findfirst(contains(r"extrinsic"), c.files))
                error("The extrinsic image in video $file at timestamp $(extrinsic - t₀), is unusable (see files in $fldr)! Please choose a different time point for the extrinsic image.")
            end
            return c, ϵ
        catch ex
            cp(path, fldr; force = true)
            throw(ex)
        end
    end
end

function get_calib_df(data_path)
    files = get_all_csv(data_path, "calibs")
    tbl = CSV.File(files; source = :csv_source, stripwhitespace = true)
    df = DataFrame(tbl)
    fix_issue_1146!(df, files)
    coalesce_df!(df, ("checker_size", "n_corners", "temporal_step", "center", "north"))
    calib_quality(df, data_path)
    # df.checker_size .= coalesce.(df.checker_size, @load_preference("checker_size"))
    # df.n_corners .= coalesce.(df.n_corners, @load_preference("n_corners"))
    # df.temporal_step .= coalesce.(df.temporal_step, @load_preference("temporal_step"))
    return df
end

# df = df[3:3,:]


# calibrate and save calibration file

function calibrate_all(df, results_dir, data_path)

    df.n .= 0
    df.reprojection .= 0.0
    df.projection .= 0.0 
    df.distance .= 0.0 
    df.inverse .= 0.0

    p = Progress(nrow(df), "Calculating all calibrations:")
    tforeach(eachrow(df)) do row
        c, ϵ = calib(joinpath(data_path, row.calibs_path, row.file), row.calibs_start, row.calibs_stop, row.extrinsic, row.checker_size, row.n_corners, row.temporal_step)
        for k in (:n, :reprojection, :projection, :distance, :inverse)
            row[k] = getfield(ϵ,k)
        end
        CameraCalibrations.save(joinpath(results_dir, row.calibration_id), c)
        next!(p)
    end
    finish!(p)
    CSV.write(joinpath(results_dir, "calib.csv"), select(df, Not(:calibs_path, :file, :calibs_start, :calibs_stop, :extrinsic, :checker_size, :n_corners, :temporal_step, :csv_source)))

end
