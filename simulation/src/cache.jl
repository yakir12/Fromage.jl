# The video cache (#297): rendering is the simulation's slow part, and it does not change when
# Fromage does, so a rig's video is rendered once and kept. A Fromage change then re-runs only the fits.

using SHA: sha256

"""
The renderer's version, part of every cached video's key. **Bump it by hand whenever what a rig
renders to changes** — the camera model, the objects, the renderer, the poses' geometry or the
encoding — or the cache keeps serving the old videos.
"""
const RENDERER_VERSION = 1

# The key of the video of `boards` seen by `cam` at `samples` × `samples`: a hash of every setting
# that decides its pixels, plus the renderer's version. `repr` prints each float in full, so a
# setting changed in its last bit is a different key; and the digest, unlike `hash`, is the same in
# every Julia session. What `repr` prints is pinned: types are named from this module, not from
# whatever the requesting session has imported, and the boards always print as the same vector type,
# because either once changed the key of an identical rig. A Julia that printed these differently
# would miss the cache, never hit a wrong video.
function cache_key(cam::Camera, boards, samples, version)
    settings = (; version, cam, boards = Union{Board, Nothing}[b for b in boards], samples)
    return bytes2hex(sha256(repr(settings; context = :module => @__MODULE__)))
end

"""
    cached_video(cache_dir, cam::Camera, boards; samples = SUPERSAMPLING) -> path

The lossless video (see [`encode`](@ref)) whose frame `k` (0-based, at `t = k` s) is `cam`'s
[`render`](@ref) of the rig with `boards[k + 1]` in view (a [`Board`](@ref), or `nothing`). It is
kept in `cache_dir` under a key of the camera, the boards, `samples` and [`RENDERER_VERSION`](@ref),
and rendered only when no video has that key yet. `cache_dir` has no default: it holds large files
and belongs outside the repository.

A video is encoded under a temporary name and moved into place once it is complete, so an
interrupted render never leaves behind a file a later request would take for finished.
"""
function cached_video(cache_dir, cam::Camera, boards::AbstractVector{<:Union{Board, Nothing}}; samples = SUPERSAMPLING)
    path = joinpath(cache_dir, cache_key(cam, boards, samples, RENDERER_VERSION) * ".mp4")
    isfile(path) && return path
    mkpath(cache_dir)
    frames = [render(cam, board; samples) for board in boards]
    partial = tempname(cache_dir; cleanup = false) * ".partial.mp4"
    try
        encode(partial, frames, cam.sar)
        mv(partial, path; force = true)
    finally
        rm(partial; force = true)
    end
    return path
end
