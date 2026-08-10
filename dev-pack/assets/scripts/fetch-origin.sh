#!/usr/bin/env bash
# fetch-origin — keep a rig's origin refs warm so reviewers and feature-dev
# fetch fast and incrementally.
#
# Runs as an exec order (no LLM, no agent, no wisp), on a short cooldown. It is
# strictly READ-ONLY with respect to working trees: it only updates remote-
# tracking refs (`git fetch --prune origin`). It never checks out, resets,
# deletes a branch, or pushes. On a large repo like vLLM a cold fetch is slow;
# this keeps each agent's own `git fetch` an incremental no-op.
#
# Env (provided to order exec by gascity): GC_CITY. Optionally override the
# target rigs with a space/comma list in GC_FETCH_RIGS (default: "vllm").
set -euo pipefail

CITY="${GC_CITY:-.}"
TARGETS="${GC_FETCH_RIGS:-vllm}"
TARGETS="${TARGETS//,/ }"

# name -> path for the rigs we care about.
RIGS_JSON=$(gc --city "$CITY" rig list --json 2>/dev/null) || exit 0

FETCHED=0
for name in $TARGETS; do
    path=$(printf '%s' "$RIGS_JSON" | jq -r --arg n "$name" \
        '.rigs[] | select(.name==$n) | .path' 2>/dev/null) || continue
    [ -n "$path" ] || continue
    [ -d "$path/.git" ] || continue

    # Read-only: update remote-tracking refs only. Skip LFS blobs — reviewers
    # and feature-dev pull what they actually need on demand.
    if GIT_LFS_SKIP_SMUDGE=1 git -C "$path" fetch --prune --quiet origin 2>/dev/null; then
        FETCHED=$((FETCHED + 1))
    fi
done

if [ "$FETCHED" -gt 0 ]; then
    echo "fetch-origin: refreshed origin refs for $FETCHED rig(s): $TARGETS"
fi
