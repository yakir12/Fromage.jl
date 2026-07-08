# End-to-end: a synthetic data folder (one checkerboard calibration video + one trackable run
# video + the two CSVs) driven through `main`, which validates both files, builds the
# rectification, tracks the run with the calibration attached, and writes the concatenated
# diagnostic video into results_dir under the current directory.
module FromageTests

using Test
using Fromage
using DataFrames: DataFrame, nrow
using FFMPEG

@testset "Fromage end-to-end (main)" begin
    dir = mktempdir()

    # calibration video: the static 500×376 checkerboard used by the VerifyCalibrations suite
    png = joinpath(@__DIR__, "VerifyCalibrations", "fixtures", "checkerboard.png")
    FFMPEG.ffmpeg_exe(`-y -loglevel error -framerate 10 -loop 1 -t 5 -i $png -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" -pix_fmt yuv420p $(joinpath(dir, "board.mp4"))`)

    # run video: a dark disc on white whose center follows a known sine (see pawsometracker.jl)
    vf = "geq=lum='if(lt(sqrt((X-55+40*sin(0.5*PI*N/25))^2+(Y-50)^2),5),0,255)':cb=128:cr=128"
    FFMPEG.ffmpeg_exe(`-y -loglevel error -f lavfi -i color=white:s=100x100:d=2:r=25 -vf $vf -pix_fmt yuv420p -qp 0 $(joinpath(dir, "target.mp4"))`)

    open(joinpath(dir, "calibs.csv"), "w") do io
        println(io, "calibration_id,file,type,extrinsic,start,stop,n_corners,checker_size")
        println(io, "c1,board.mp4,video,1,0,4,\"(5, 8)\",4")
    end
    open(joinpath(dir, "runs.csv"), "w") do io
        println(io, "calibration_id,file,target_width,start_location")
        println(io, "c1,target.mp4,10,\"(55, 50)\"")
    end

    # main writes results_dir/diagnostic.mp4 relative to the current directory
    outdir = mktempdir()
    runs = cd(() -> main(dir), outdir)

    @test runs isa DataFrame
    @test nrow(runs) == 1
    t, ij = only(runs.run)                          # each run entry is track's (timestamps, coords)
    @test length(ij) == 50                          # the full 2 s at 25 fps
    @test only(runs.calibration).ratio > 0          # the joined rectification is a real one
    @test isfile(joinpath(outdir, "results_dir", "diagnostic.mp4"))
    @test filesize(joinpath(outdir, "results_dir", "diagnostic.mp4")) > 0
end

end
