# Where Fromage writes what it produces. `main`'s output folder and the gateway's issues folder each
# used to carry their own "results_dir" literal with nothing keeping the two in step, so the default
# and both subfolder names are spelled here — before any submodule is defined — and nowhere else.
module Paths

using Dates: format, now, @dateformat_str

# The output folder a caller who names none gets, created in the folder Julia was started in (see
# docs/src/results.md): the tracks, the diagnostic videos, and the two subfolders below. `main` and
# `verify` take the folder as their `results_dir` keyword and pass it down to everything that writes
# (#229), so this is only ever a default — nothing reads it in place of the folder it was handed.
# The BINDING is upper-case like every other constant here; the VALUE is the folder name users
# see on disk and in the docs, and must not change — renaming it would relocate every existing
# user's output.
const RESULTS_DIR = "results_dir"

# The two fixed subfolders of whatever output folder is in force, spelled here and nowhere else. They
# are user-visible (docs/src/results.md), so like `RESULTS_DIR` their values must not change.
#
# One warped extrinsic frame per rectification, written only when a caller asks for them (`main`'s
# `rectification_diagnostics`).
const RECTIFICATIONS_FOLDER = "rectifications"
# The parent of the per-invocation issue folders (see `invocation_issues_dir`).
const ISSUES_FOLDER = "issues"

rectifications_folder(results_dir) = joinpath(results_dir, RECTIFICATIONS_FOLDER)
issues_folder(results_dir) = joinpath(results_dir, ISSUES_FOLDER)

# One folder per INVOCATION — one execution of Fromage — named for the moment that invocation
# started, so its folder holds exactly what it dumped, with nothing deleted to keep it that way.
# Fromage never removes anything from the issues folder: cleaning it out is the user's call, not a
# side effect of verifying (#86).
#
# "Invocation", and neither of the two words it is easily confused with (CONTEXT.md defines all
# three). Not "run": a `Run` in this package is an experimental run — one repeat of an experiment,
# one animal crossing the arena — and has nothing to do with how many times Fromage was executed.
# The function was `run_issues_dir`, which read as "the issues folder of a given Run" and meant the
# opposite. Not "session" either: that is the Julia PROCESS, which outlives any one execution and is
# what the memo caches live in (see `Memo`) — this folder is per execution, and a session that calls
# `main` three times gets three of them.
#
# Nothing is created here: `save_issue_frame` mkpaths the folder when it dumps its first frame, so an
# invocation with nothing to report leaves no trace at all. The counter is what makes back-to-back
# invocations distinct — it skips a second that already has a folder. Two invocations starting within
# the same second and both dumping frames would land in one folder (unwritten folders cannot be
# counted), but an invocation reads video off disk before it can fail a detection, so that race isn't
# reachable.
function invocation_issues_dir(issues)
    stamp = format(now(), dateformat"yyyy-mm-dd\THH-MM-SS")
    dir = joinpath(issues, stamp)
    n = 1
    while ispath(dir)
        n += 1
        dir = joinpath(issues, string(stamp, '_', n))
    end
    return dir
end

end
