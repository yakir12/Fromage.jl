# The process-global memo behind the iterate-on-your-csv workflow (#233).
#
# A user fixing a dataset runs `main`, reads the report, edits one row, and runs `main` again. Every
# call used to re-do all of verification from cold — one ffprobe per physical video, one `matread`
# per `.mat`, corner detection at each rectification's extrinsic timestamp, and a scan of each
# intrinsic window — including for the rows they did not touch. On the lab share every one of those
# reads is slow and occasionally fails (see WHY-FRAMES-FAIL.md), so the second call cost as much as
# the first for no new information. These caches make it cost nothing.
#
# Everything memoized here is a PURE function of its arguments plus the contents of a file on disk.
# Nothing that mutates a DataFrame is memoized: its effect is the mutation, not the return value,
# and a DataFrame hashes by object identity, so a memo there would either never hit or serve a stale
# frame. The frame dump a failing extrinsic writes is likewise outside the memo — only the DETECTOR
# is cached, so every invocation still dumps its own frame into its own folder (#86, #210).
#
# **The key is the memoized function's complete argument list.** That is the rule, and it is what
# makes an under-specified key — the one way this could return a WRONG answer rather than merely a
# slow one — impossible to write: there is no argument the cached function can read that the key
# does not carry. Read the `get!` at each call site against the function's signature and the two
# must be the same list. Arguments are hashed by VALUE (paths are strings, timestamps and counts are
# numbers), never by object identity, so the same specification always finds the same entry.
#
# A failed READ is never remembered, and that is the other half of the contract: see `remember`
# below for why, and for the two shapes it takes. What is remembered is a VERDICT — what ffprobe
# said, what the detector found — never "the file could not be read", which is a fact about the
# share at that moment and not about the file at all.
#
# LIFETIME AND INVALIDATION. A cache lives as long as the Julia process — the SESSION, in this
# package's vocabulary (CONTEXT.md). A cached read is never revalidated against the file: file
# identity is the resolved, canonical absolute path and nothing else. `mtime` + size was considered
# and declined (DECISIONS, "The memo is keyed on the path, and never revalidated"), so replacing a
# file's contents in place while the REPL is alive — re-copying a corrupt video, re-exporting a
# `.mat` — requires `Fromage.empty_caches!()` or a fresh Julia process. Same for a `Revise.jl` user
# who has redefined one of the memoized functions.
module Memo

using LRUCache: LRU, cache_info

# One size for every cache here. The reference dataset is 372 runs over a handful of rectifications,
# so a thousand entries holds a whole session's worth of anything with room to spare, and the bound
# exists only so a pathological loop cannot grow one without limit.
const CACHE_SIZE = 1000

# `LRU` is the cache, and the choice is load-bearing rather than incidental: the reads it wraps run
# under `OhMyThreads.tmap`, so every one of these is written concurrently, and `LRU` both locks and
# RELEASES the lock while computing a missing value. A lock held across an ffprobe or a detection
# would serialize exactly the parallelism the gateways exist to get. DECISIONS, "LRUCache, not a
# memoization package", records what the alternatives do instead.
newcache(::Type{K}, ::Type{V}) where {K, V} = LRU{K, V}(maxsize = CACHE_SIZE)

# `Probing.probe_fields(file, entries)` — one ffprobe spawn per (physical file, `-show_entries`
# spec). Memoized at the shared spawn rather than in each gateway's `probe_video`, so the runs
# gateway and the rectifications gateway share one cache; they ask for different entries, so a file
# used by both is still probed once per gateway, exactly as before.
#
# The value is ffprobe's `key => value` output, or the issue string of a file it could not read.
# Callers only ever `get` from that Dict; it is shared, so nothing may mutate it.
const VIDEO_PROBES = newcache(Tuple{String, String}, Dict{String, String})

# `VerifyRectifications.matlab_metadata(file)` — one `matread` per physical `.mat`, plus the
# structure/extrinsic-count/`ImageSize` derivation off the same dict. The DERIVED metadata is
# cached, not the parsed dict: the dict is the large object, and nothing outside that function reads
# it.
const MATLAB_METADATA = newcache(Tuple{String}, Union{String, NamedTuple{(:n_extrinsics, :dimension)}})

# The three detection caches key on a bare `Tuple` where the two file reads name their element types:
# a detector's arguments arrive from a `detect_per_group!` group key, so their concrete types are the
# csv parsers' business rather than this module's, and pinning them here would be a second place to
# state them. `K` is only the dict's hashing; `V` is what the caller sees, and every one of these is
# declared concretely enough to keep `get!` inferring it.
#
# `VerifyRectifications.extrinsic_issue(...)` — checkerboard corner detection at one rectification's
# extrinsic timestamp — and `PawsomeTracker.apriltag_extrinsic_issue(...)`, the AprilTag analogue.
# Two caches rather than one because the two detectors take different argument lists, which is to
# say they are asking different questions of the frame.
const EXTRINSIC_DETECTIONS = newcache(Tuple, Union{Nothing, String})
const APRILTAG_DETECTIONS = newcache(Tuple, Union{Nothing, String})

# `VerifyRectifications.intrinsic_issue(...)` — the scan of a rectification's intrinsic window for
# three frames with detectable corners. The most expensive of the lot on a bad window, which scans
# to the end.
const INTRINSIC_DETECTIONS = newcache(Tuple, Union{Nothing, String})

# A failed READ is never remembered. It is a fact about the share at that moment and not about the
# file (WHY-FRAMES-FAIL.md), so the next invocation must be free to retry it rather than re-report a
# hiccup for the life of the session — which would break the very workflow this memo exists for.
#
# Three of the five computations get that for free by catching OUTSIDE `get!`, which stores nothing
# when its closure throws. This is for the other two, whose catch belongs to a function that reports
# rather than throws (`read_matlab`, `reference_space`) and has callers relying on that: remember
# what `f` returned, `unless` it is one of those reports, which is then forgotten.
#
# `unless` recognizes the failure by the very prefix the message is built from — one definition site
# each (`MATLAB_READ_FAILURE`, `EXTRINSIC_READ_FAILURE`), because a recognizer that had drifted from
# its message would silently remember the failure forever.
#
# Another thread can read the entry between the store and the delete. That costs one extra report of
# the same failure inside the same invocation, which is what a single `detect_per_group!` group
# would have produced anyway.
function remember(f, cache, key; unless)
    value = get!(f, cache, key)
    unless(value) && delete!(cache, key)
    return value
end

# Every cache in this module, so `Fromage.empty_caches!` cannot be left behind by a new one — and so
# a test can assert that it wasn't (test/memo.jl). A tuple of the caches themselves rather than of
# their names: it is what `empty!` is mapped over.
const CACHES = (VIDEO_PROBES, MATLAB_METADATA, EXTRINSIC_DETECTIONS, APRILTAG_DETECTIONS, INTRINSIC_DETECTIONS)

# What a cache has served and what it had to compute — the only honest way to assert that a second
# verification read nothing, since wall-clock time on this machine is noise (DECISIONS, "Wall-clock
# benchmarks on this machine are noise"). Named here so nothing outside this module has to reach for
# LRUCache itself; note that `empty!` resets both counters.
hits(cache) = cache_info(cache).hits
misses(cache) = cache_info(cache).misses

end # module Memo
