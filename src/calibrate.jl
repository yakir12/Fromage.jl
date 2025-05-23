function extract(extrinsic, file, path, blur)
    to = joinpath(path, "$extrinsic extrinsic.png")
    if blur == 0
        ffmpeg_exe(` -loglevel 8 -ss $extrinsic -i $file -vf yadif=1 -vframes 1 $to`)
    else
        ffmpeg_exe(` -loglevel 8 -ss $extrinsic -i $file -vf yadif=1,gblur=sigma=$blur -vframes 1 $to`)
    end
    # to
end
function extract(ss, stop, file, path, temporal_step, blur)
    t = stop - ss
    r = 1/temporal_step
    to = joinpath(path, "intrinsic%04d.png")
    if blur == 0
        ffmpeg_exe(` -loglevel 8 -ss $ss -i $file -t $t -r $r -vf yadif=1 $to`)
    else
        ffmpeg_exe(` -loglevel 8 -ss $ss -i $file -t $t -r $r -vf yadif=1,gblur=sigma=$blur $to`)
    end
    # readdir(path, join = true)
end
# function seek_snap(path, vid, t, name = t)
#     seek(vid, t)
#     img = read(vid)
#     save(joinpath(path, "$name.png"), img)
# end

function calib(plot_folder, file, start, stop, extrinsic, checker_size, n_corners, temporal_step, with_distortion, blur)
    # VideoIO.FFMPEG.@ffmpeg_env run(`$(FFMPEG.ffmpeg) -loglevel 8 -ss $extrinsic -i $video -vf format=gray,yadif=1,scale=sar"*"iw:ih -pix_fmt gray -vframes 1 $to`)
    # vid = openvideo(file, target_format=VideoIO.AV_PIX_FMT_GRAY8, )
    # read(vid)
    # t₀ = gettime(vid)
    # start += t₀
    # stop += t₀
    # extrinsic += t₀
    ts = range(start, stop, step = temporal_step)
    mktempdir() do path
        extract(extrinsic, file, path, blur)
        extract(start, stop, file, path, temporal_step, blur)
        fldr = basename(path)
        # foreach(t -> seek_snap(path, vid, t), ts)
        # seek_snap(path, vid, extrinsic, "extrinsic")
        files = readdir(path; join=true)
        aspect = openvideo(VideoIO.aspect_ratio, file)
        # aspect = VideoIO.aspect_ratio(vid)
        try
            c, ϵ = fit(files, n_corners, checker_size; aspect, with_distortion, plot_folder)
            if isnothing(findfirst(contains(r"extrinsic"), c.files))
                error("The extrinsic image in video $file at timestamp $extrinsic, is unusable (see files in $fldr)! Please choose a different time point for the extrinsic image. Or try perhaps different `n_corners`, right now it's $n_corners.")
            end
            return c, ϵ
        catch ex
            # TODO: either fix CameraCalibrations.jl with OpenCV.jl 
            # or
            # switch to using CameraCalibrations.jl#main
            cp(path, fldr; force = true)
            open(joinpath(fldr, "error.log"), "w") do io
                print(io, ex)
            end
            @warn "Something went wrong with the calibration in video $file at timestamp $extrinsic (see files in $fldr)!"
            throw(ex)
        end
    end
end

function get_calib_df(data_path)
    files = get_all_csv(data_path, "calibs")
    tbl = CSV.File(files; source = :csv_source, stripwhitespace = true)#, types = Dict(:calibs_start => String, :calibs_stop => String, :extrinsic => String))
    df = DataFrame(tbl)
    fix_issue_1146!(df, files)
    return df
end

# df = df[3:3,:]

xy2ij(file, ::Missing) = missing

function xy2ij(file, xy)
    sar = openvideo(VideoIO.aspect_ratio, file)
    round.(Int, (last(xy), first(xy) / sar))
end

function xy2ij(file, xys::Vector)
    sar = openvideo(VideoIO.aspect_ratio, file)
    [round.(Int, (last(xy), first(xy) / sar)) for xy in xys]
end

# calibrate and save calibration file

function calibrate_all(calibs, results_dir, data_path)

    # # TODO: rm
    # subset!(calibs, :calibration_id => ByRow(==("20230112_mirror_dance01_spontaneous_ID29.MTS")))
    # subset!(calibs, :calibs_recording_datetime => ByRow(>(Date(2025))))

    transform!(calibs, [:calibs_path, :file, :center] => ByRow((p, f, c) -> xy2ij(joinpath(data_path, p, f), c)) => :center_ij)
    transform!(calibs, [:calibs_path, :file, :north] => ByRow((p, f, c) -> xy2ij(joinpath(data_path, p, f), c)) => :north_ij)

    stats = (:n, :reprojection, :projection, :distance, :inverse)
    for k in stats
        calibs[!, k] .= 0.0
    end

    p = Progress(nrow(calibs); desc = "Calculating all calibrations:")
    ϵs = map(eachrow(calibs)) do row
        c, ϵ = calib(joinpath(results_dir, "debug_$(row.calibration_id)"), joinpath(data_path, row.calibs_path, row.file), row.calibs_start, row.calibs_stop, row.extrinsic, row.checker_size, row.n_corners, row.temporal_step, row.with_distortion, row.blur)
        CameraCalibrations.save(joinpath(results_dir, row.calibration_id), c)
        next!(p)
        return ϵ
    end
    finish!(p)
    for (row, ϵ) in zip(eachrow(calibs), ϵs)
        for k in stats
            row[k] = getfield(ϵ, k)
        end
    end
    # p = Progress(nrow(calibs), "Calculating all calibrations:")
    # foreach(eachrow(calibs)) do row
    #     c, ϵ = calib(joinpath(data_path, row.calibs_path, row.file), row.calibs_start, row.calibs_stop, row.extrinsic, row.checker_size, row.n_corners, row.temporal_step)
    #     for k in stats
    #         row[k] = getfield(ϵ, k)
    #     end
    #     CameraCalibrations.save(joinpath(results_dir, row.calibration_id), c)
    #     next!(p)
    # end
    # finish!(p)
    CSV.write(joinpath(results_dir, "calibs.csv"), rename(select(calibs, Not(:csv_source)), :file => :calibs_file))

end
