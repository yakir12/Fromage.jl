struct Tag
    c::SV
end

function set_detector!(detector, n=2)
    detector.nThreads = Threads.nthreads()
    detector.quad_decimate =  1.0
    detector.quad_sigma = 0.0
    detector.refine_edges = 1
    detector.decode_sharpening = 0.25
    return detector
end

struct DetectoRect
    sz::NTuple{2, Int}
    detector::AprilTagDetector
    rect::MVector{4, Int}
    min_radius::Float64
    function DetectoRect(sz)
        detector = AprilTagDetector()
        set_detector!(detector)
        new(sz, detector, MVector(1, 1, sz...), 10)
    end
end

Base.close(d::DetectoRect) = freeDetector!(d.detector)

function Tag(tag, r1, c1)
    # center
    c0 = SV(reverse(tag.H[1:2,3]))
    # global center
    c = c0 + SV(r1, c1)
    Tag(c)
end

function (d::DetectoRect)(buff)
    r1, c1, r2, c2 = d.rect
    cropped = buff[r1:r2, c1:c2]
    # detect
    tags = d.detector(cropped)
    if length(tags) ≠ 1 # not found
        d.rect[1:2] .= max.(1, d.rect[1:2] .- widen_radius)
        d.rect[3:4] .= min.(d.sz, d.rect[3:4] .+ widen_radius)
        return nothing
    else
        b = Tag(only(tags), r1, c1)
        d.rect[1:2] .= max.(1, round.(Int, b.c .- d.min_radius::Float64))
        d.rect[3:4] .= min.(d.sz, round.(Int, b.c .+ d.min_radius::Float64))
        return b
    end
end







function detect(guess, stack, j, h, img, radii, buff, kernel, sz, scale, bkgd_reduce = maximum)
    slice = selectdim(stack, 3, j)
    bkgd_indices = CartesianIndices(UnitRange.(guess .- h, guess .+ h)) ∩ CartesianIndices(Base.OneTo.(sz))
    img.data[bkgd_indices] .= slice[bkgd_indices] #.- bkgd_reduce(stack[bkgd_indices, :], dims = 3)
    window_indices = UnitRange.(guess .- radii, guess .+ radii)
    imfilter!(CPUThreads(Algorithm.FIR()), buff, img, kernel, NoPad(), window_indices)
    v = view(buff, window_indices...)
    clamp!(v, 0, Inf)
    coord = _weightedmean(v)
    if any(isnan, coord)
        return RowCol(guess) / scale, guess
    end
    # coord = min.(max.(coord, (1, 1)), sz)
    guess = Tuple(round.(Int, coord))
    # return scaleit(coord, scale), guess
    return coord / scale, guess
end

function track!(coords, stack, guess, tr, vid, dia)
    for i in axes(stack, 3)
        coords[i], guess = detect(guess, stack, i, tr.h, tr.img, tr.radii, tr.buff, tr.kernel, tr.sz, vid.scale, tr.bkgd_reduce)
        dia(selectdim(parent(parent(stack)), 3, i), round.(Int, Tuple(coords[i])))
    end
    n_bkgd = size(stack, 3)
    for i in n_bkgd + 1:vid.nframes
        next!(vid)
        j = mod1(i, n_bkgd)
        # populate_slice!(selectdim(parent(stack), 3, j), vid)
        # populate_slice!(selectdim(parent(parent(stack)), 3, j), vid)
        populate_slice!(stack, j, vid)
        coords[i], guess = detect(guess, stack, j, tr.h, tr.img, tr.radii, tr.buff, tr.kernel, tr.sz, vid.scale, tr.bkgd_reduce)
        dia(selectdim(parent(parent(stack)), 3, j), round.(Int, Tuple(coords[i])))
    end
end

function track_one(file, start, stop, target_width, start_location, window_size, darker_target, fps, dia, apriltags, initial_search_factor, white_point, scale, apriltags)
    video(file, fps, start, stop, scale) do vid
        detectors = [DetectoRect(vid.sz) for _ in 1:apriltags]
        update_ratio!(dia, size(vid.img))
        tr = Tracker(vid, darker_target, target_width, window_size)
        stack = collect_stack(vid, tr.sz, tr.h)
        coords = Vector{RowCol}(undef, vid.nframes)
        guess = get_guess(start_location, stack, vid, darker_target, target_width, initial_search_factor)
        track!(coords, stack, guess, tr, vid, dia)
        return (range(start, stop, vid.nframes), coords)
    end
end

function track(
        file::AbstractString;
        start::Real = 0,
        stop::Real = get_duration(file),
        target_width::Real = 25,
        start_location::Union{Missing, NTuple{2, Int}, CartesianIndex{2}} = missing,
        window_size::Union{Missing, Int, NTuple{2, Int}} = round(Int, 2target_width),
        darker_target::Bool = true,
        fps::Real = get_framerate(file),
        diagnostic_file::Union{Nothing, AbstractString} = nothing,
        apriltags::Int = 0,
        initial_search_factor::Real=4,
        scale::Real = 1,
        white_point::Real = 1,
        rectification = nothing # rectification object
    )
    if apriltags > 0
    diagnose(diagnostic_file, darker_target, apriltags, fps) do dia
        track_one(file, start, stop, scale*target_width, start_location, round.(Int, scale .* fix_window_size(window_size)), darker_target, fps, dia, apriltags, scale * initial_search_factor, white_point, scale, apriltags)
    end
end


# function get_p(tags, n)
#     RowCol.(reverse.(reshape(stack(getfield.(tags, :p)), 4n)))
# end
#
# function findHomography(src, dst, n)
#     # mask = Matrix{Float64}(undef, 3, 3)
#     h, mask = OpenCV.findHomography(OpenCV.Mat(reshape(reinterpret(Float32, src), 2, 4n, 1)), OpenCV.Mat(reshape(reinterpret(Float32, dst), 2, 4n, 1)))#, OpenCV.Mat(reshape(mask, 1, 3, 3)), 2000, 0.995)
#     # h, mask = OpenCV.findHomography(OpenCV.Mat(reshape(reinterpret(Float32, src), 2, 1, 4n)), OpenCV.Mat(reshape(reinterpret(Float32, dst), 2, 1, 4n)), OpenCV.RANSAC, 5.0, OpenCV.Mat(reshape(mask, 1, 3, 3)), 2000, 0.995)
#     SMatrix{3,3}(reshape(h, 3 ,3))'
# end
#
# push1 = Base.Fix2(push, 1)
#
# function track_one(file, start, stop, target_width, start_location, window_size, darker_target, fps, dia, apriltags, initial_search_factor, white_point)
#     # start and stop are taken as absolutes. To guarantee that, `ts` is set using `length` rather than the `step` key-word
#     t = stop - start
#     n = round(Int, fps * t) + 1
#     ts = range(start, stop, n)
#     indices = Vector{NTuple{2, Int}}(undef, n)
#     xys = Vector{Union{Missing, RowCol}}(undef, n)
#
#     bkgd = get_bkgd(file, start, stop)
#
#     openvideo(file; target_format = AV_PIX_FMT_GRAY8) do vid
#         vid_fps = framerate(vid)
#         if isinf(vid_fps)
#             vid_fps = get_framerate(file)
#         end
#         skip = round(Int, vid_fps / fps) - 1
#         # img = Matrix{out_frame_eltype(vid)}(undef, out_frame_size(vid))
#         img = read(vid)
#         update_ratio!(dia, size(img))
#         seek(vid, start)
#         read!(vid, img) # and do something
#         if !iszero(apriltags)
#             detector = AprilTagDetector()
#             tags = detector(collect(img))
#             if length(tags) == apriltags
#                 dst = get_p(tags, apriltags)
#                 tag = tags[1]
#                 H = inv(SMatrix{3,3}(tag.H))
#             else
#                 @error "less than $apriltags AprilTags were detected" length(tags)
#             end
#         end
#         trckr, indices[1] = get_start_ij_and_tracker(start_location, vid, img, target_width, window_size, darker_target, initial_search_factor, white_point, bkgd)
#         for i in 2:n
#             skipframes(vid, skip, throwEOF = false)
#             if eof(vid)
#                 ts = ts[1:i-1]
#                 deleteat!(indices, i:n)
#                 break
#             end
#             read!(vid, trckr.img.data)
#             indices[i] = trckr(indices[i - 1])
#             dia(trckr.img.data, indices[i])
#             if !iszero(apriltags)
#                 tags = detector(collect(trckr.img.data))
#                 if length(tags) == apriltags
#                     src = get_p(tags, apriltags)
#                     h = findHomography(src, dst, apriltags)
#                     trans = LinearMap(SDiagonal(96/2, 96/2)) ∘ pop ∘ LinearMap(H) ∘ LinearMap(h) ∘ push1 ∘ RowCol
#                     xys[i] = trans(indices[i])
#                 end
#             end
#             # @show i
#         end
#     end
#     return ts, CartesianIndex.(indices), xys
#
#     # frame_index = openvideo(open(cmd), target_format = AV_PIX_FMT_GRAY8) do vid
#     #     last_frame::Int = 1
#     #     img = read(vid)
#     #     update_ratio!(dia, size(img))
#     #     trckr, indices[1] = get_start_ij_and_tracker(start_location, vid, img, target_width, window_size, darker_target)
#     #     while !eof(vid) && last_frame < n
#     #         last_frame += 1
#     #         read!(vid, trckr.img.data)
#     #         indices[last_frame] = trckr(indices[last_frame - 1])
#     #         dia(trckr.img.data, indices[last_frame])
#     #     end
#     #     return last_frame
#     # end
#     # return ts[1:frame_index], CartesianIndex.(indices[1:frame_index])
# end


end
