# TODO — deferred work

Parked ideas and follow-ups, so they don't get lost.

## AprilTag tracking

- **CI test for the AprilTag path.** The geometry has synthetic unit tests, but the detection +
  single-pass tracking loop (`track_apriltag`) and `DiagnoseApriltag` are only validated live
  against real drone footage. A CI test needs a synthetic drone video: a moving disc plus four
  rendered `tag36h11` tags, warped per frame by a time-varying homography (drone motion), with the
  disc's known ground path as ground truth. Doable with the ffmpeg generator but non-trivial — do
  it once phases 4–5 land and the path is feature-complete.

- **API consolidation.** Right now AprilTag mode rides on `track`'s existing `apriltags` (tag count)
  and `rectification` kwargs, kept as-is deliberately. Later: consolidate these, and add the
  AprilTag calibration/rectification *type* into the VerifyRectifications → Rectifications gateway
  (a new `type = apriltag` calibs.csv row), so a whole drone run flows through `main` like the other
  rectification kinds.

- **Fold registration into the lazy-scaling pipe (could stabilize the background model).** Scaling
  is currently lazy — it only scales the *indices* into an interpolation object (a `WarpedView`),
  at essentially no compute cost. The per-frame registration homography is the same kind of
  operation (a coordinate transform on lookups), so it could be composed into that same pipe for
  very little cost. That would effectively warp each frame into the reference frame as it's read,
  making the DoG background stack *static* (drone motion removed at lookup time) — likely a much
  more stable background model than tracking in native image space. Revisit if the background model
  ever proves to be the limiting factor.

- **Keep frames as `Gray{N0f8}` through PawsomeTracker.** The background stack is `Gray{Float32}`
  but the AprilTag detector only accepts `Gray{N0f8}`/`UInt8`, so `track_apriltag` re-detects on the
  raw `vid.img` each frame with a `collect` conversion instead of reusing the stack slices. If the
  frames stayed `N0f8` (or the stack slices were detector-compatible), detection could run directly
  on the stack. Check whether the DoG path (imfilter, background subtraction) tolerates `N0f8`.
