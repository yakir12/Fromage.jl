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
const VIDEO_PROBES = newcache(Tuple{String, String}, Union{Dict{String, String}, String})

# `VerifyRectifications.matlab_metadata(file)` — one `matread` per physical `.mat`, plus the
# structure/extrinsic-count/`ImageSize` derivation off the same dict. The DERIVED metadata is
# cached, not the parsed dict: the dict is the large object, and nothing outside that function reads
# it.
const MATLAB_METADATA = newcache(Tuple{String}, Union{String, NamedTuple})

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
