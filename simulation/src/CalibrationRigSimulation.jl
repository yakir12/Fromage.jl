"""
    CalibrationRigSimulation

A physical simulation of the arena and camera, the ground truth Fromage's checkerboard
rectification is checked against (#289). A research instrument: it reports, it gates nothing.

Fromage is a dependency for the builders the later rungs call; the camera model here is the
simulation's own and uses nothing of Fromage's, nor of OpenCV's.
"""
module CalibrationRigSimulation

export Camera, project, ray

include("camera.jl")

end
