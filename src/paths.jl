# Where Fromage writes what it produces. `main`'s output folder and the gateway's issues folder each
# used to carry their own "results_dir" literal with nothing keeping the two in step, so both are
# derived here — before any submodule is defined — and there is one string to change.
module Paths

using Dates: format, now, @dateformat_str

# Every output lands under this folder, created in the folder Julia was started in (see
# docs/src/results.md): the tracks, the diagnostic videos, and the issue frames below.
# The BINDING is upper-case like every other constant here; the VALUE is the folder name users
# see on disk and in the docs, and must not change — renaming it would relocate every existing
# user's output.
const RESULTS_DIR = "results_dir"

# One warped extrinsic frame per calibration, written only when a caller asks for them (`main`'s
# `rectification_diagnostics`). Derived here like every other output location, so there is still one
# string to change.
const RECTIFICATIONS_DIR = joinpath(RESULTS_DIR, "rectifications")

# The parent of the per-run issue folders (see `run_issues_dir`), and the default a caller who names
# no folder of their own gets.
const DEFAULT_ISSUES_DIR = joinpath(RESULTS_DIR, "issues")

# One folder per verification run, named for the moment the run started, so a run's folder holds
# exactly what that run dumped — with nothing deleted to keep it that way. Fromage never removes
# anything from the issues folder: cleaning it out is the user's call, not a side effect of running
# a verification (#86).
#
# Nothing is created here: `save_issue_frame` mkpaths the folder when it dumps its first frame, so a
# run with nothing to report leaves no trace at all. The counter is what makes back-to-back runs
# distinct — it skips a second that already has a folder. Two runs starting within the same second
# and both dumping frames would land in one folder (unwritten folders cannot be counted), but a
# verification run reads video off disk before it can fail a detection, so that race isn't reachable.
function run_issues_dir(issues_dir)
    stamp = format(now(), dateformat"yyyy-mm-dd\THH-MM-SS")
    dir = joinpath(issues_dir, stamp)
    n = 1
    while ispath(dir)
        n += 1
        dir = joinpath(issues_dir, string(stamp, '_', n))
    end
    return dir
end

end
