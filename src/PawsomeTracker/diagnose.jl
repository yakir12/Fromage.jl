# Constants for diagnostic video generation
const DIAGNOSTIC_VIDEO_SIZE = (360, 640)
# Every rectified segment renders into this fixed square canvas so all segments of the combined
# diagnostic share one resolution — mandatory for the stream-copy concatenation (mixed-size
# segments in one H.264 stream decode at the first segment's dimensions). The warp's zoom adapts
# per rectification instead; see DiagnoseRectified.
const DIAGNOSTIC_SIZE = 540
const TRACE_BUFFER_SIZE = 100
# Diagnostic videos play back at DIAGNOSTIC_SPEEDUP × real time, decimated to roughly
# DIAGNOSTIC_FPS frames per second of playback — so long runs skim quickly and a high tracking
# fps no longer slows playback down (the writer's framerate used to be left at VideoIO's default
# 24 while every tracked frame was written, playing a 50 fps track at 0.48× speed).
const DIAGNOSTIC_SPEEDUP = 2
const DIAGNOSTIC_FPS = 24
# FreeType faces are stateful (one glyph slot per face) and FreeTypeAbstraction's per-face lock is
# not held across load → read → copy, so concurrently tracked runs sharing one global face can
# swap each other's label glyphs (a run briefly labeled with another run's id). Each writer
# therefore loads its own private face from this font file.
const FONT = @path joinpath(@__DIR__, "assets", "TeXGyreHerosMakie-Regular.otf")

# Write every `skip`-th tracked frame, and declare the playback framerate that makes the segment
# play at exactly DIAGNOSTIC_SPEEDUP × real time with ≈ DIAGNOSTIC_FPS frames per second.
diagnostic_stride(fps) = max(1, round(Int, DIAGNOSTIC_SPEEDUP * fps / DIAGNOSTIC_FPS))
diagnostic_framerate(fps, skip) = DIAGNOSTIC_SPEEDUP * fps / skip
# Constant-quality H.264 encoding. Diagnostic files must be .mp4: that container's default codec
# is H.264, whose crf option these settings configure (the old .ts segments defaulted to MPEG-2
# at libavcodec's default *average bitrate* — constant bits per second that turned into mush as
# the tracking fps rose).
const DIAGNOSTIC_ENCODER = (crf = 23, preset = "veryfast")

abstract type Diagnosis end

struct Diagnose <: Diagnosis
    label::String
    buffer::Matrix{Gray{N0f8}}
    color::Gray{N0f8}
    writer::VideoWriter
    trace::CircularBuffer{CartesianIndex{2}}
    ratio::Ref{NTuple{2, Float64}}
    state::Ref{Int}
    skip::Int
    face::FTFont

    function Diagnose(file::AbstractString, darker_target, fps)
        label = first(splitext(basename(file)))
        buff_sz = DIAGNOSTIC_VIDEO_SIZE
        buffer = Matrix{Gray{N0f8}}(undef, buff_sz...)
        color = darker_target ? Gray{N0f8}(1) : Gray{N0f8}(0)
        skip = diagnostic_stride(fps)
        writer = open_video_out(file, buffer; framerate = diagnostic_framerate(fps, skip),
            encoder_private_options = DIAGNOSTIC_ENCODER)
        trace = CircularBuffer{CartesianIndex{2}}(TRACE_BUFFER_SIZE)
        ratio = Ref{NTuple{2, Float64}}()
        return new(label, buffer, color, writer, trace, ratio, Ref(0), skip, FTFont(String(FONT)))
    end
end
diagnose(file::AbstractString, darker_target::Bool, ::Nothing, fps) = Diagnose(file, darker_target, fps)

function update_ratio!(dia::Diagnose, sz)
    return dia.ratio[] = size(dia.buffer) ./ sz
end

function (dia::Diagnose)(img, point)
    dia.state[] += 1
    if rem(dia.state[], dia.skip) == 0
        ij = CartesianIndex(round.(Int, point .* dia.ratio[]))
        push!(dia.trace, ij)
        imresize!(dia.buffer, img)
        renderstring!(dia.buffer, dia.label, dia.face, 20, 20, 20, halign = :hleft, valign = :vtop)
        draw!(dia.buffer, CirclePointRadius(ij, 7; thickness = 3, fill = false), dia.color)
        draw!(dia.buffer, Path(dia.trace), dia.color)
        write(dia.writer, dia.buffer)
    end
    return nothing
end

Base.close(dia :: Diagnosis) = close_video_out!(dia.writer)

struct Dont end
# `file` (the diagnostic_file) is nothing: no diagnostic video requested, whatever the rectification.
diagnose(::Nothing, _, _, _) = Dont()
(::Dont)(_, _) = nothing
Base.close(::Dont) = nothing
update_ratio!(::Dont, _) = nothing

function diagnose(f, file, darker_target, rectification, fps)
    dia = diagnose(file, darker_target, rectification, fps)
    return try
        f(dia)
    finally
        close(dia)
    end
end

struct DiagnoseRectified <: Diagnosis
    label::String
    # buffer::OffsetMatrix{Gray{N0f8}, Matrix{Gray{N0f8}}}
    indices
    color::Gray{N0f8}
    writer::VideoWriter
    trace::CircularBuffer{CartesianIndex{2}}
    state::Ref{Int}
    skip::Int
    image2real
    real2image
    radius::Int
    font::Int
    face::FTFont

    function DiagnoseRectified(file::AbstractString, darker_target, rect, fps)
        label = first(splitext(basename(file)))
        # Fixed canvas: the zoom adapts so the frame's smaller dimension always spans the canvas.
        # For a 1080p source this is exactly the former half-resolution view (the old
        # m = min(w, h) ÷ 2 with a hardcoded 2× zoom is the special case m = DIAGNOSTIC_SIZE when
        # min(w, h) = 1080) — detail stays discernible while every segment is the same size.
        m = DIAGNOSTIC_SIZE
        D = LinearMap(SDiagonal{2}((min(rect.width, rect.height) / m) * rect.ratio * I))
        real2image = rect.real2image ∘ D
        image2real = inv(D) ∘ rect.image2real
        indices = (-m÷2:m÷2 - 1, -m÷2:m÷2 - 1)
        buffer = OffsetMatrix(Matrix{Gray{N0f8}}(undef, m, m), indices...)
        color = darker_target ? Gray{N0f8}(1) : Gray{N0f8}(0)
        skip = diagnostic_stride(fps)
        writer = open_video_out(file, parent(buffer); framerate = diagnostic_framerate(fps, skip),
            encoder_private_options = DIAGNOSTIC_ENCODER)
        trace = CircularBuffer{CartesianIndex{2}}(TRACE_BUFFER_SIZE)
        return new(label, indices, color, writer, trace, Ref(0), skip, image2real, real2image, m ÷ 30, m ÷ 16, FTFont(String(FONT)))
    end
end
diagnose(file::AbstractString, darker_target::Bool, rectification, fps) = DiagnoseRectified(file, darker_target, rectification, fps)

function (dia::DiagnoseRectified)(img, point)
    dia.state[] += 1
    if rem(dia.state[], dia.skip) == 0
        ij = CartesianIndex(Tuple(round.(Int, dia.image2real(point))))
        push!(dia.trace, ij)
        wimg = warp(Gray{N0f8}.(img), dia.real2image, dia.indices; fillvalue = zero(Gray{N0f8}))
        draw!(wimg, CirclePointRadius(ij, dia.radius; thickness = dia.radius ÷ 2, fill = false), dia.color)
        draw!(wimg, Path(dia.trace), dia.color)
        wimg = parent(wimg)
        renderstring!(wimg, dia.label, dia.face, dia.font, dia.font, dia.font, halign = :hleft, valign = :vtop)
        write(dia.writer, wimg)
    end
    return nothing
end

update_ratio!(::DiagnoseRectified, _) = nothing
