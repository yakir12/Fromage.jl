"""
    CalibrationRigSimulation

A physical simulation of the arena and camera, the ground truth Fromage's checkerboard
rectification is checked against (#289). A research instrument: it reports, it gates nothing.

Fromage is a dependency for the builders the later rungs call; the camera model, the renderer and
the dot detector here are the simulation's own and use nothing of Fromage's, nor of OpenCV's.
"""
module CalibrationRigSimulation

export Camera, project, ray
export Board, inner_corners, trace
export render
export BASELINE_CAMERA, board_poses, corner_projections
export detect_dots, area_centroid

# the later files name `Camera` and `Board` in signatures, and the dot detector's background is the
# arena's reflectance, both evaluated when the file is included: the camera and the objects go first
include("camera.jl")
include("objects.jl")
include("render.jl")
include("poses.jl")
include("dots.jl")

end
