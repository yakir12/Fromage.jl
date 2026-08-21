# Constants for diagnostic video generation
const DIAGNOSTIC_VIDEO_SIZE = (360, 640)
# Every rectified segment renders into this fixed square canvas so all segments of the combined
# diagnostic share one resolution — mandatory for the stream-copy concatenation (mixed-size
# segments in one H.264 stream decode at the first segment's dimensions). The warp's zoom adapts
# per rectification instead; see DiagnoseRectified.
const DIAGNOSTIC_SIZE = 540
const TRACE_BUFFER_SIZE = 100
# Diagnostic videos play back at DIAGNOSTIC_SPEEDUP × real time, decimated to roughly
# DIAGNOSTIC_FPS frames per second of playback, so long runs skim quickly and a high tracking fps
# doesn't slow playback down.
const DIAGNOSTIC_SPEEDUP = 2
const DIAGNOSTIC_FPS = 24
# FreeType faces are stateful (one glyph slot per face) and FreeTypeAbstraction's per-face lock is
# not held across load → read → copy, so concurrently tracked runs sharing one global face swap
# each other's label glyphs. Each writer loads its own private face from this font file.
const FONT = @path joinpath(@__DIR__, "assets", "TeXGyreHerosMakie-Regular.otf")

# Write every `skip`-th tracked frame, and declare the playback framerate that makes the segment
# play at exactly DIAGNOSTIC_SPEEDUP × real time with ≈ DIAGNOSTIC_FPS frames per second.
diagnostic_stride(fps) = max(1, round(Int, DIAGNOSTIC_SPEEDUP * fps / DIAGNOSTIC_FPS))
diagnostic_framerate(fps, skip) = DIAGNOSTIC_SPEEDUP * fps / skip
# Constant-quality H.264 encoding. Diagnostic files must be .mp4: that container's default codec
# is H.264, whose crf option these settings configure.
const DIAGNOSTIC_ENCODER = (crf = 23, preset = "veryfast")

abstract type Diagnosis end

# All three diagnostics do the same thing with a tracked frame: on every `skip`-th one, render it to
# a canvas, ring the target, trail the last TRACE_BUFFER_SIZE marks behind it, stamp the run's label
# (#22) and write. What differs is only how the frame becomes a canvas and where the target lands on
# it — that is the `scene`, and it is the only thing a fourth diagnostic would have to supply.
#
# A scene is a callable `(frame, point, extra...) -> (canvas, ij)`, where `ij` may be `missing` on a
# frame the mode cannot locate the target in (the marker and trace are then skipped, the frame is
# still written). `canvas_prototype(scene)` gives the writer its frame size and element type.
struct Diagnostic{S} <: Diagnosis
    label::String
    writer::VideoWriter
    trace::CircularBuffer{CartesianIndex{2}}
    state::Ref{Int}
    skip::Int
    color::Gray{N0f8}
    radius::Int
    font::Int
    face::FTFont          # private per writer; see the FONT note above
    scene::S
end

function Diagnostic(file::AbstractString, darker_target, fps, scene; radius, font)
    skip = diagnostic_stride(fps)
    writer = open_video_out(file, canvas_prototype(scene); framerate = diagnostic_framerate(fps, skip),
        encoder_private_options = DIAGNOSTIC_ENCODER)
    return Diagnostic(first(splitext(basename(file))), writer,
        CircularBuffer{CartesianIndex{2}}(TRACE_BUFFER_SIZE), Ref(0), skip,
        darker_target ? Gray{N0f8}(1) : Gray{N0f8}(0), radius, font, FTFont(String(FONT)), scene)
end

# Written frames are 1, skip+1, 2*skip+1, … — the counter is tested BEFORE it is bumped. Bumping
# first tested the opening frame as `rem(1, skip)`, so the one frame that shows where tracking
# actually began was the one frame never written, unless the stride happened to be 1. That is the
# frame a reader checking for a wrong `start_location` needs (see results.md).
function (dia::Diagnostic)(frame, point, extra...)
    write_now = rem(dia.state[], dia.skip) == 0
    dia.state[] += 1
    write_now || return nothing
    canvas, ij = dia.scene(frame, point, extra...)
    if !ismissing(ij)
        push!(dia.trace, ij)
        draw!(canvas, CirclePointRadius(ij, dia.radius; thickness = max(1, dia.radius ÷ 2), fill = false), dia.color)
        draw!(canvas, Path(dia.trace), dia.color)
    end
    # A warped canvas is offset-indexed; the writer wants the plain storage behind it (a no-op for
    # the raw scene, whose canvas already is that storage). The label goes on last, so it stays
    # legible wherever the target happens to be.
    out = parent(canvas)
    renderstring!(out, dia.label, dia.face, dia.font, dia.font, dia.font, halign = :hleft, valign = :vtop)
    write(dia.writer, out)
    return nothing
end

Base.close(dia::Diagnosis) = close_video_out!(dia.writer)

struct Dont end
# `file` (the diagnostic_file) is nothing: no diagnostic video requested, whatever the rectification.
diagnose(::Nothing, _, _, _) = Dont()
(::Dont)(_, _) = nothing
(::Dont)(_, _, _) = nothing                    # 3-arg no-op for the apriltag callback
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

# Only the raw scene has anything to update; the warping ones map through a rectification that is
# fixed at construction, so they answer with a no-op.
update_ratio!(dia::Diagnostic, sz) = update_ratio!(dia.scene, sz)

# --- the scenes ---------------------------------------------------------------------------------

# Unrectified: the raw frame resized into a fixed canvas, reusing one buffer across frames. The
# frame size is not known until tracking opens the video, so the point→canvas ratio is filled in by
# `update_ratio!` before the first write.
struct RawScene
    buffer::Matrix{Gray{N0f8}}
    ratio::Ref{NTuple{2, Float64}}
end
RawScene() = RawScene(Matrix{Gray{N0f8}}(undef, DIAGNOSTIC_VIDEO_SIZE...), Ref{NTuple{2, Float64}}())
canvas_prototype(s::RawScene) = s.buffer
update_ratio!(s::RawScene, sz) = s.ratio[] = size(s.buffer) ./ sz
function (s::RawScene)(img, point)
    imresize!(s.buffer, img)
    return s.buffer, CartesianIndex(round.(Int, point .* s.ratio[]))
end

diagnose(file::AbstractString, darker_target::Bool, ::Nothing, fps) =
    Diagnostic(file, darker_target, fps, RawScene(); radius = 7, font = 20)

# Rectified: the frame warped onto the ground plane, into a fixed square canvas with the zoom
# adapting so the frame's smaller dimension always spans it — detail stays discernible while every
# segment comes out the same size (mandatory for the stream-copy concatenation; see DIAGNOSTIC_SIZE).
struct RectifiedScene{I, R}
    indices::NTuple{2, UnitRange{Int}}
    image2real::I
    real2image::R
end

function RectifiedScene(rect)
    m = DIAGNOSTIC_SIZE
    D = LinearMap(SDiagonal{2}((min(rect.width, rect.height) / m) * rect.ratio * I))
    return RectifiedScene((-m÷2:m÷2 - 1, -m÷2:m÷2 - 1), inv(D) ∘ rect.image2real, rect.real2image ∘ D)
end

canvas_prototype(s::RectifiedScene) = Matrix{Gray{N0f8}}(undef, length.(s.indices)...)
update_ratio!(::RectifiedScene, _) = nothing

function (s::RectifiedScene)(img, point)
    wimg = warp(Gray{N0f8}.(img), s.real2image, s.indices; fillvalue = zero(Gray{N0f8}))
    return wimg, CartesianIndex(Tuple(round.(Int, s.image2real(point))))
end

diagnose(file::AbstractString, darker_target::Bool, rectification, fps) =
    Diagnostic(file, darker_target, fps, RectifiedScene(rectification);
               radius = DIAGNOSTIC_SIZE ÷ 30, font = DIAGNOSTIC_SIZE ÷ 16)
