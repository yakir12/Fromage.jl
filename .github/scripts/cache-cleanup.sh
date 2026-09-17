#!/usr/bin/env bash
# Deletes Actions caches that no job can restore any more, to keep the repository under GitHub's
# 10 GB cache limit (#138). Run by .github/workflows/CacheCleanup.yml, which says when each mode
# runs; runnable locally too, with an authenticated `gh`, and dry-run unless DRY_RUN=false.
#
#   cache-cleanup.sh pr <number>   every cache on refs/pull/<number>/merge
#   cache-cleanup.sh all           tags, closed PRs' refs, and superseded caches on main
#
# Every failure is fatal and nothing is silenced: a cleanup that reports success after doing
# nothing is indistinguishable from one that had nothing to do.
set -euo pipefail
# Without this, a failure inside `$(…)` does not stop the function running there.
shopt -s inherit_errexit

repo=${GITHUB_REPOSITORY:-yakir12/Fromage.jl}
dry_run=${DRY_RUN:-true}
limit=1000

caches=$(gh cache list --repo "$repo" --limit "$limit" --json id,key,ref,sizeInBytes,createdAt)
count=$(jq length <<<"$caches")
if ((count >= limit)); then
    echo "::error::Listed $count caches, the --limit asked for; the listing may be truncated, so nothing was deleted."
    exit 1
fi
echo "Listed $count caches on $repo."

# A tag build's ref reads `refs/heads/refs/tags/v…`, so match `refs/tags/` anywhere, not as a prefix.
tag_caches='map(select(.ref | contains("refs/tags/")))'

# julia-actions/cache never prunes the default branch, so main keeps a generation per run. Group
# by the key with its `;run_id=…;run_attempt=…` suffix removed — not by known key prefixes, so a
# new key shape still groups — and keep the newest of each group. `createdAt`'s fractional seconds
# vary in length, so it is compared as numbers rather than as a string; the id breaks ties.
superseded_main_caches='
    map(select(.ref == "refs/heads/main"))
    | group_by(.key | sub(";run_id=[^;]*;run_attempt=[^;]*$"; ""))
    | map(sort_by(
            (.createdAt | (capture("^(?<s>[^.]+?)(?<f>\\.[0-9]+)?Z$") // error("unparseable createdAt: \(.)"))
             | [(.s + "Z" | fromdateiso8601), ("0" + (.f // "") | tonumber)]),
            .id)
          | .[:-1])
    | add // []'

pr_caches() { jq --arg ref "refs/pull/$1/merge" 'map(select(.ref == $ref))' <<<"$caches"; }

closed_pr_caches() {
    local numbers number state selected='[]'
    numbers=$(jq -r '.[].ref | capture("^refs/pull/(?<n>[0-9]+)/merge$").n' <<<"$caches" | sort -un)
    for number in $numbers; do
        state=$(gh pr view "$number" --repo "$repo" --json state --jq .state)
        if [[ $state != OPEN ]]; then
            selected=$(jq --argjson more "$(pr_caches "$number")" '. + $more' <<<"$selected")
        fi
    done
    echo "$selected"
}

mode=${1:?usage: cache-cleanup.sh pr <number> | all}
case $mode in
    pr) candidates=$(pr_caches "${2:?usage: cache-cleanup.sh pr <number>}") ;;
    all)
        # No process substitution here: its exit status is discarded, so a failure would be lost.
        tags=$(jq "$tag_caches" <<<"$caches")
        main=$(jq "$superseded_main_caches" <<<"$caches")
        prs=$(closed_pr_caches)
        candidates=$(jq -n --argjson a "$tags" --argjson b "$main" --argjson c "$prs" '$a + $b + $c | unique_by(.id)')
        ;;
    *)
        echo "::error::Unknown mode '$mode'."
        exit 1
        ;;
esac

n=$(jq length <<<"$candidates")
if ((n == 0)); then
    echo "No caches to delete; nothing was deleted."
    exit 0
fi

bytes=$(jq 'map(.sizeInBytes) | add' <<<"$candidates")
if [[ $dry_run == false ]]; then verb=Deleting; else verb="Dry run, would delete"; fi
echo "$verb $n caches, $bytes bytes:"
jq -r 'sort_by(.ref, .key)[] | "  \(.id)  \(.sizeInBytes)  \(.ref)  \(.key)"' <<<"$candidates"

if [[ $dry_run == false ]]; then
    # Into a variable first: a failure in a `for` loop's word list does not stop the script.
    ids=$(jq -r '.[].id' <<<"$candidates")
    for id in $ids; do
        gh cache delete "$id" --repo "$repo"
    done
    echo "Deleted $n caches."
else
    echo "Dry run: nothing was deleted."
fi
