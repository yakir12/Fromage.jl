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

# All three diagnostics do the same thing with a tracked frame: on every `skip`-th one, render it to
# a canvas, ring the target, trail the last TRACE_BUFFER_SIZE marks behind it, stamp the run's label
# (#22) and write. What differs is only how the frame becomes a canvas and where the target lands on
# it — that is the `scene`, and it is the only thing a fourth diagnostic would have to supply.
#
# A scene is a callable `(frame, point, extra...) -> (canvas, ij)`, where `ij` may be `missing` on a
# frame the mode cannot locate the target in (the marker and trace are then skipped, the frame is
# still written). `canvas_prototype(scene)` gives the writer its frame size and element type.
struct Diagnostic{S}
    label::String
    writer::VideoWriter
    trace::CircularBuffer{CartesianIndex{2}}
    # `Base.RefValue`, not `Ref`, for the same reason as `RawScene.ratio` below: `Ref` is
    # abstract, so the field would be boxed. The constructor's `Ref(0)` already makes a
    # `RefValue{Int}` — only the declaration was loose.
    state::Base.RefValue{Int}
    skip::Int
    color::Gray{N0f8}
    radius::Int
    font::Int
    face::FTFont          # private per writer; see the FONT note above
    scene::S
end

# The open comes LAST: every fallible step is done while there is nothing to leak — the font load
# especially, which reads a file from disk, and used to sit between the open and the return with
# nothing holding the writer if it threw (#160). The guard covers what the ordering cannot: the
# field conversion the inner constructor does is still a step after the open, as would be anything
# a later edit adds there.
function Diagnostic(file::AbstractString, darker_target, fps, scene; radius, font)
    skip = diagnostic_stride(fps)
    label = first(splitext(basename(file)))
    trace = CircularBuffer{CartesianIndex{2}}(TRACE_BUFFER_SIZE)
    color = darker_target ? Gray{N0f8}(1) : Gray{N0f8}(0)
    face = FTFont(String(FONT))
    writer = open_video_out(file, canvas_prototype(scene); framerate = diagnostic_framerate(fps, skip),
        encoder_private_options = DIAGNOSTIC_ENCODER)
    built = false
    return try
        dia = Diagnostic(label, writer, trace, Ref(0), skip, color, radius, font, face, scene)
        built = true
        dia
    finally
        # A flag, because `finally` cannot tell success from failure on its own. `catch; discard;
        # rethrow()` would do the same job — the flag is what keeps a catch-everything out of a
        # package whose rule against them has an issue number (DECISIONS, "No bare `catch`").
        built || discard(file) do
            close_video_out!(writer)
        end
    end
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

Base.close(dia::Diagnostic) = close_video_out!(dia.writer)

struct Dont end
# `file` (the diagnostic_file) is nothing: no diagnostic video requested, whatever the rectification.
diagnose(::Nothing, _, _, _) = Dont()
# Shaped like `Diagnostic`'s own call signature, so the two stay in step: the apriltag callback
# passes a third argument, anything else passes two.
(::Dont)(_, _, _...) = nothing
Base.close(::Dont) = nothing
update_ratio!(::Dont, _) = nothing

# An export that did not finish is not a diagnostic: the encoder wrote a header and however many
# frames it got to, and neither the concatenation nor a user opening the file can tell that
# truncation from a short run. So the failure path closes the writer AND takes the file with it,
# while the success path keeps what it wrote (#160). `file` is `nothing` when no diagnostic was
# asked for — `dia` is then a `Dont`, and there is nothing to close or remove.
function with_diagnostic(f, dia, file)
    finished = false
    return try
        result = f(dia)
        close(dia)          # finalization: the writer flushes and writes its trailer here, so a
        finished = true     # failure in it is a failure of the export like any other
        result
    finally
        # One rule, no exceptions: an export stopped by Ctrl-C is a failed export too, and its file
        # goes with the rest. Interrupting `main` loses them anyway — its diagnostics live in a
        # `mktempdir` that unwinds with the exception.
        finished || discard(file) do
            close(dia)
        end
    end
end

# Cleanup must not become the failure the caller sees: an exception raised inside a `catch` or a
# `finally` silently replaces the one already on its way out, which is the one that explains what
# went wrong. BOTH steps here can fail — `close_video_out!` through ffmpeg, `rm` through the
# filesystem — so each is guarded on its own, which also means a close that fails does not cost us
# the removal. Two closes are safe: `close_video_out!` frees its pointers in its own `finally` and
# no-ops on a writer already closed.
function discard(close!, file)
    warn_on_failure(close!, "close the diagnostic")
    warn_on_failure(() -> remove_partial(file), "remove the partial diagnostic")
    return nothing
end

# Deliberately broad, in the same shape as the precompile workloads and `save_issue_frame`: what
# ffmpeg and the filesystem report here is a plain `ErrorException`/`IOError` with nothing narrower
# to match on, and the point is precisely that NOTHING from cleanup reaches the caller. The
# exception is not lost — it goes to the log, with its backtrace. Ctrl-C still gets through. The
# cost is that a `MethodError` from a bug in here is demoted to a warning too (DECISIONS).
function warn_on_failure(step!, what)
    try
        step!()
    catch e
        e isa InterruptException && rethrow()
        @warn "could not $what while cleaning up after an earlier failure" exception = (e, catch_backtrace())
    end
    return nothing
end

remove_partial(file::AbstractString) = rm(file; force = true)   # `force`: the open may have thrown
remove_partial(::Nothing) = nothing                             # before ffmpeg created anything

# `darker_target::Bool` for the same reason the four-argument forms annotate it: the two do-block
# forms take `rectification` and `darker_target` in opposite orders, and with nothing annotated a
# transposed call would compile and run (see `reference_size` in apriltag.jl on unassertable
# transpositions). The annotation makes the swap a `MethodError`.
diagnose(f, file, darker_target::Bool, rectification, fps) =
    with_diagnostic(f, diagnose(file, darker_target, rectification, fps), file)

# Only the raw scene has anything to update; the warping ones map through a rectification that is
# fixed at construction, so they answer with a no-op.
update_ratio!(dia::Diagnostic, sz) = update_ratio!(dia.scene, sz)

# --- the scenes ---------------------------------------------------------------------------------

# Unrectified: the raw frame resized into a fixed canvas, reusing one buffer across frames. The
# frame size is not known until tracking opens the video, so the point→canvas ratio is filled in by
# `update_ratio!` before the first write.
struct RawScene
    buffer::Matrix{Gray{N0f8}}
    # `Base.RefValue`, not `Ref`: `Ref` is abstract, so the field would be boxed. `Ref{T}()` below
    # already constructs a `RefValue{T}` — only the declaration was loose.
    ratio::Base.RefValue{NTuple{2, Float64}}
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

# `convert`, not `Gray{N0f8}.(img)`: the frame handed here is a slice of the stack, which stores
# `Gray{N0f8}` already (#27), so the broadcast was an identity copy of the whole frame on every
# written frame. `convert(AbstractArray{T}, A)` returns `A` itself when the eltype matches and
# converts otherwise, so the fallback for anything else is unchanged.
function (s::RectifiedScene)(img, point)
    wimg = warp(convert(AbstractArray{Gray{N0f8}}, img), s.real2image, s.indices; fillvalue = zero(Gray{N0f8}))
    return wimg, CartesianIndex(Tuple(round.(Int, s.image2real(point))))
end

diagnose(file::AbstractString, darker_target::Bool, rectification, fps) =
    Diagnostic(file, darker_target, fps, RectifiedScene(rectification);
               radius = DIAGNOSTIC_SIZE ÷ 30, font = DIAGNOSTIC_SIZE ÷ 16)
