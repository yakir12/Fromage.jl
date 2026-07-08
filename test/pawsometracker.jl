# Direct PawsomeTracker coverage. The former package's test files were dev scratch (they
# referenced a local dataset folder and a hard-coded mounted video), so this compact suite
# replaces them, reusing the synthetic-trajectory generator proven in the VerifyRuns suite:
# ffmpeg's geq renders a disc whose display-space center follows x(N) = col − A·sin(0.5π·N/fps),
# y(N) = row, encoded losslessly so the analytic ground truth is exact. (VerifyRuns'
# test_tracking.jl additionally exercises track through the gateway, including anamorphic and
# scaled variants.)
module PawsomeTrackerTests

using Test
using Fromage.PawsomeTracker: track
using FFMPEG
using Statistics: mean

const DATADIR = mktempdir()

function make_target_video(name; width = 100, height = 100, fps = 25, duration = 2,
        target_width = 10, darker_target = true, row = 50, col = 55, nsegments = 1)
    A = width / 2.5
    target_c, bkgd_c = darker_target ? (0, 255) : (255, 0)
    vf = "geq=lum='if(lt(sqrt((X-$col+$A*sin(0.5*PI*N/$fps))^2+(Y-$row)^2),$(target_width/2)),$target_c,$bkgd_c)':cb=128:cr=128"
    src = `-y -loglevel error -f lavfi -i color=white:s=$(width)x$(height):d=$duration:r=$fps -vf $vf -pix_fmt yuv420p -qp 0`
    files = if nsegments == 1
        FFMPEG.ffmpeg_exe(`$src $(joinpath(DATADIR, "$name.mp4"))`)
        [joinpath(DATADIR, "$name.mp4")]
    else
        T = duration / nsegments
        kf = "expr:gte(t,n_forced*$T)"
        FFMPEG.ffmpeg_exe(`$src -force_key_frames $kf -f segment -segment_time $T $(joinpath(DATADIR, name * "_%02d.mp4"))`)
        [joinpath(DATADIR, string(name, "_", lpad(k, 2, '0'), ".mp4")) for k in 0:(nsegments - 1)]
    end
    # 1-based stored-frame (row, col) of the disc center at sample i (frame offset + (i − 1)·skip)
    expected = (i; skip = 1, offset = 0) -> begin
        N = offset + (i - 1) * skip
        (row + 1.0, col - A * sin(0.5π * N / fps) + 1)
    end
    return files, expected
end

"RMSE (pixels) between tracked coordinates and the ground-truth closure."
function tracking_rmse(ij, expected; skip = 1, offset = 0)
    sqrt(mean([sum(abs2, Tuple(rc) .- expected(i; skip, offset)) for (i, rc) in enumerate(ij)]))
end

@testset "PawsomeTracker" begin
    base, base_exp = make_target_video("pt_base")
    light, light_exp = make_target_video("pt_light"; darker_target = false)
    seg, seg_exp = make_target_video("pt_seg"; nsegments = 3)

    @testset "single video, explicit start_location" begin
        _, ij = track(only(base); start_location = (55, 50), target_width = 10)
        @test length(ij) == 50                       # the full 2 s at 25 fps
        @test tracking_rmse(ij, base_exp) < 1
    end

    @testset "defaults (frame-center start)" begin
        _, ij = track(only(base))
        @test tracking_rmse(ij, base_exp) < 1
    end

    @testset "reduced fps tracks every other frame" begin
        _, ij = track(only(base); fps = 12.5)
        @test length(ij) == 25
        @test tracking_rmse(ij, base_exp; skip = 2) < 1
    end

    @testset "lighter target on dark background" begin
        _, ij = track(only(light); darker_target = false)
        @test tracking_rmse(ij, light_exp) < 1
    end

    @testset "segmented (vector) track" begin
        sls = Vector{Union{Missing, NTuple{2, Int}}}(missing, length(seg))
        sls[1] = (55, 50)                            # later segments continue from the previous one
        _, ij = track(seg; start_location = sls)
        @test length(ij) == 50
        @test tracking_rmse(ij, seg_exp) < 1
    end

    @testset "diagnostic file is written" begin
        df = joinpath(DATADIR, "diag.ts")
        track(only(base); diagnostic_file = df)
        @test isfile(df)
        @test filesize(df) > 0
    end
end

end
