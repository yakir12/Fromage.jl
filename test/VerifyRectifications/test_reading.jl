@testset "file reading (durations & dimensions)" begin
    # A clean load returns Vector{RectificationMethod}; :dimension/:duration are intermediate validation
    # columns. One ffprobe per video file (probe_video) returns width/height/duration/aspect/yadif;
    # matlab metadata derives from one matread, exercised here through the dict-based helpers.
    @testset "valid video -> probe_video metadata" begin
        m = VRect.probe_video(joinpath(DATADIR, ART.video))   # video.mp4: 640x480, progressive
        @test m.width == 640
        @test m.height == 480
        @test m.duration ≈ VIDEO_DURATION atol = 0.5
        @test m.aspect == 1.0
        @test m.yadif == false
    end

    @testset "valid matlab -> dimension" begin
        # good.mat ImageSize [480,640] -> (640,480)
        @test VRect.matlab_dimension(MAT.matread(joinpath(DATADIR, ART.good_mat))) == (640, 480)
    end

    @testset "matlab with nested ImageSize (findfirstkey recursion)" begin
        @test VRect.matlab_dimension(MAT.matread(joinpath(DATADIR, ART.nested_mat))) == (640, 480)
    end

    @testset "corrupt video is flagged for both video and only_scale" begin
        # probe_video's catch returns the message string; assert it directly, then end-to-end through
        # load_rectifications for both types (both reach probe_video via read_video_metadata!).
        @test VRect.probe_video(joinpath(DATADIR, ART.corrupt)) isa String
        @test flagged(check([videorow(file = ART.corrupt)]), 1, "issue reading from video file")
        @test flagged(check([scalerow(file = ART.corrupt)]), 1, "issue reading from video file")
    end

    @testset "non-mat file is flagged" begin
        df = check([matlabrow(matlab_file = ART.bad_mat)])
        @test flagged(df, 1, "missing \"MATLAB\" magic bytes")
    end

    @testset "matlab magic bytes" begin
        # A real MAT-file begins with the ASCII text "MATLAB"; matlab_magic_issue returns nothing for
        # a genuine .mat and a message otherwise. bad.mat ("this is not a mat file") fails the check.
        @test VRect.matlab_magic_issue(joinpath(DATADIR, ART.good_mat)) === nothing
        @test VRect.matlab_magic_issue(joinpath(DATADIR, ART.bad_mat))  isa String
        # an unreadable path (here: absent) is a SystemError from `read`, reported as an issue
        @test VRect.matlab_magic_issue(joinpath(DATADIR, "definitely_not_here.mat")) isa String
        # end-to-end: a non-mat file is flagged and has :matlab_file nulled (the source video :file is fine)
        df = check([matlabrow(matlab_file = ART.bad_mat)])
        @test flagged(df, 1, "missing \"MATLAB\" magic bytes")
        @test ismissing(df.matlab_file[1])
    end

    @testset "unreadable only_scale file is now always opened (no lazy skip)" begin
        # Every row now reads its source video to fill the shared Source width/height/aspect, so a
        # corrupt only_scale video is flagged even when center/north are absent (a lazy skip
        # optimization is gone).
        df = check([scalerow(file = ART.corrupt, center = missing, north = missing)])
        @test flagged(df, 1, "issue reading from video file")
    end

    @testset "matlab structure: required calibration fields" begin
        # matlab_missing_keys returns nothing when all of MATLAB_REQUIRED_KEYS are present (searched
        # nested), and a message listing the absent ones otherwise. read_matlab turns a non-mat /
        # unreadable file into an issue string before any dict is produced.
        @test VRect.matlab_missing_keys(MAT.matread(joinpath(DATADIR, ART.good_mat)))    === nothing
        @test VRect.matlab_missing_keys(MAT.matread(joinpath(DATADIR, ART.nested_mat)))  === nothing
        @test VRect.matlab_missing_keys(MAT.matread(joinpath(DATADIR, ART.partial_mat))) isa String
        @test VRect.read_matlab(joinpath(DATADIR, ART.bad_mat))                          isa String  # unreadable / not a mat

        # end-to-end: a structurally-complete matlab row loads clean...
        @test clean(check([matlabrow()]))                 # good.mat has all fields
        @test clean(check([matlabrow(matlab_file = ART.nested_mat)]))

        # ...while a file missing required fields is flagged, names the missing fields, and has :matlab_file nulled.
        df = check([matlabrow(matlab_file = ART.partial_mat)])
        @test flagged(df, 1, "missing required calibration field(s)")
        @test flagged(df, 1, "TranslationVectors")
        @test flagged(df, 1, "RotationVectors")
        @test ismissing(df.matlab_file[1])
    end

    @testset "matlab ImageSize must match the source video dimensions" begin
        # good.mat ImageSize is (640,480); pairing it with board.mp4 (500×376) as the source video
        # makes the cross-check fail. (matlabrow's default source video.mp4 is 640×480 and passes.)
        df = check([matlabrow(file = ART.board)])
        @test flagged(df, 1, "does not match the source video dimensions")
    end

    @testset "same physical .mat via different path spellings is grouped for reading" begin
        # "." and "./." resolve to the same dir, so both rows point at one physical .mat. The reading
        # passes group on the canonical (realpath) matlab_file, so the file is read once and the result
        # is applied to every spelling — here a structure failure is reported on both rows.
        df = check([matlabrow(calibration_id = "c1", path = ".",   matlab_file = ART.partial_mat, center = missing, north = missing),
                    matlabrow(calibration_id = "c2", path = "./.", matlab_file = ART.partial_mat, center = missing, north = missing)])
        @test flagged(df, 1, "missing required calibration field(s)")
        @test flagged(df, 2, "missing required calibration field(s)")

        # likewise a video read (dimension) applied across spellings: an out-of-bounds center is caught
        # on both rows from the one read.
        df = check([videorow(calibration_id = "v1", path = ".",   center = (9000, 9000)),
                    videorow(calibration_id = "v2", path = "./.", center = (9000, 9000))])
        @test flagged(df, 1, "center cannot be larger than the dimensions")
        @test flagged(df, 2, "center cannot be larger than the dimensions")
    end

    @testset "save_issue_frame is best-effort, but does not swallow interrupts" begin
        # The frame reader is injected, so both failure kinds can be driven directly. A failed read
        # must leave verification unharmed (nothing returned, nothing thrown)...
        dir = joinpath(DATADIR, "issues_besteffort")
        @test VRect.save_issue_frame(dir, "v.mp4", 1.0, () -> error("no frame")) === nothing
        @test !isdir(dir)                       # nothing created when the frame never arrived
        # ...while a Ctrl-C during the read propagates instead of being absorbed as a failed save.
        @test_throws InterruptException VRect.save_issue_frame(dir, "v.mp4", 1.0, () -> throw(InterruptException()))
    end

    @testset "corner-detection failures are classified, not caught blindly" begin
        # What the real pipeline raises (see the _detection_failure comment): a seek yielding no
        # frame, OpenCV's C++ errors, and the frame read itself.
        @test VRect._detection_failure(DimensionMismatch("new dimensions"))
        @test VRect._detection_failure(ErrorException("OpenCV(4.13.0) … findChessboardCorners"))
        @test VRect._detection_failure(SystemError("open", 2))
        # A bug here, or a Ctrl-C, is not a detection failure and must propagate.
        @test !VRect._detection_failure(InterruptException())
        @test !VRect._detection_failure(MethodError(identity, ()))
        @test !VRect._detection_failure(BoundsError([1], 2))
    end

    @testset "task-wrapped failures are unwrapped before classifying" begin
        # tmap wraps a failure in a TaskFailedException only when it actually spawned; the same
        # error arrives bare when the work ran inline. Both shapes must reach the same verdict.
        bare = ErrorException("boom")
        wrapped = try fetch(Threads.@spawn error("boom")) catch e; e end
        @test wrapped isa TaskFailedException
        @test VRect._unwrap_task(wrapped) isa ErrorException
        @test VRect._detection_failure(VRect._unwrap_task(wrapped))
        @test VRect._unwrap_task(bare) === bare
        @test VRect._unwrap_task(CompositeException([bare])) === bare
        # an interrupt raised inside a task still refuses classification once unwrapped
        interrupted = try fetch(Threads.@spawn throw(InterruptException())) catch e; e end
        @test !VRect._detection_failure(VRect._unwrap_task(interrupted))
    end

    @testset "matlab without ImageSize is flagged" begin
        # matlab_dimension guards findfirstkey(...) === nothing and returns the "does not contain any
        # image size" message instead of crashing when ImageSize is absent.
        @test VRect.matlab_dimension(MAT.matread(joinpath(DATADIR, ART.noimsize_mat))) isa String
    end

    @testset "single-type CSV (no per-type fillers) loads" begin
        # parse_row back-fills every COLUMNS entry with missing, so a video-only CSV (which never
        # creates the :scale column) must not make verifications! throw `column :scale not found`.
        csv = write_rows(joinpath(DATADIR, "videoonly.csv"), [videorow()])   # no fillers
        @test (VRect.load_rectifications(DATADIR, csv; strict = false); true)
    end

    @testset "malformed ImageSize is flagged, never thrown" begin
        # ImageSize present but the wrong shape/eltype must yield an issue string, not an uncaught
        # error (InexactError/MethodError) and not a silently-wrong dimension.
        for (nm, val) in ("three_elem" => [1, 2, 3], "noninteger" => [1.5, 2.5],
                          "scalar" => 42, "stringval" => "hello")
            p = joinpath(DATADIR, "badimsize_$nm.mat")
            # include the required calibration fields so the structure check passes and the row
            # reaches the ImageSize validation under test.
            MAT.matwrite(p, merge(Dict("ImageSize" => val), MATLAB_CALIB_FIELDS))
            @testset "$nm" begin
                @test VRect.matlab_dimension(MAT.matread(p)) isa String
            end
        end
        # end-to-end: such a file is flagged, and load_rectifications does not throw
        @test flagged(check([matlabrow(matlab_file = "badimsize_three_elem.mat")]), 1, "ImageSize is malformed")
    end
end
