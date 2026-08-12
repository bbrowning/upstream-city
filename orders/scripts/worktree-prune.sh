#!/usr/bin/env bash
# worktree-prune — clean stale git-worktree registrations from all rigs.
#
# Slot worktrees (dev-pack lanes, PR review scratch, etc.) sometimes get their
# backing directory removed without `git worktree remove` (a lane rename, a
# manual cleanup, a crash mid-teardown). The registration lingers in
# .git/worktrees/ forever unless something prunes it. `git worktree prune`
# only ever removes an entry whose recorded gitdir is already gone from disk —
# it never touches a worktree that's still there, in-flight or not — so this
# is safe to run unconditionally on every rig, including HQ.
#
# Runs as an exec order (no LLM, no agent, no wisp). See wo-oqyy.
set -euo pipefail

RIGS=$(gc rig list --json 2>/dev/null | jq -r '.rigs[].path' 2>/dev/null) || exit 0
if [ -z "$RIGS" ]; then
    exit 0
fi

while IFS= read -r rig_path; do
    [ -d "$rig_path/.git" ] || continue

    OUTPUT=$(git -C "$rig_path" worktree prune -v 2>&1) || continue
    if [ -n "$OUTPUT" ]; then
        echo "worktree-prune: $rig_path"
        echo "$OUTPUT"
    fi
done <<< "$RIGS"

exit 0
