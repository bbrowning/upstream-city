#!/usr/bin/env bash
# Materialize one GitHub PR head in the rig's shared object store before dispatch.
#
# The fetch lands in a private staging ref first.  Only after the fetched commit
# matches GitHub's advertised head do we atomically create the immutable ready
# ref.  Linked reviewer worktrees can therefore resolve the returned SHA as soon
# as they are dispatched; they never have to race each other to fetch it.
set -euo pipefail

usage() {
    printf '%s\n' 'usage: materialize-pr-head.sh --repo PATH --pr NUMBER' >&2
    exit 2
}
die_infra() {
    printf 'materialize-pr-head: infrastructure failure (%s): %s\n' "$1" "$2" >&2
    exit 3
}

REPO="" PR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:?}"; shift 2 ;;
        --pr) PR="${2:?}"; shift 2 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done
[ -n "$REPO" ] && [[ "$PR" =~ ^[0-9]+$ ]] || usage
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die_infra pr-repository-unavailable "not a git worktree: $REPO"
command -v gh >/dev/null 2>&1 \
    || die_infra pr-head-metadata-unavailable 'gh is not installed'

META=$(cd "$REPO" && gh api "repos/{owner}/{repo}/pulls/$PR" 2>/dev/null) \
    || die_infra pr-head-metadata-unavailable "could not resolve PR #$PR"
ADVERTISED=$(printf '%s' "$META" | jq -er '.head.sha' 2>/dev/null) \
    || die_infra pr-head-metadata-unavailable "PR #$PR has no advertised head SHA"

FORMAT=$(git -C "$REPO" rev-parse --show-object-format 2>/dev/null || printf sha1)
case "$FORMAT:$ADVERTISED" in
    sha1:????????????????????????????????????????|sha256:????????????????????????????????????????????????????????????????) ;;
    *) die_infra pr-head-metadata-invalid "PR #$PR advertised an invalid $FORMAT object id" ;;
esac

STAGE="refs/gc/pr-head-staging/$PR/$$"
READY="refs/gc/pr-heads/$PR/$ADVERTISED"
ZERO=$(printf '%*s' "${#ADVERTISED}" '' | tr ' ' 0)
cleanup() { git -C "$REPO" update-ref -d "$STAGE" >/dev/null 2>&1 || true; }
trap cleanup EXIT

GIT_LFS_SKIP_SMUDGE=1 git -C "$REPO" fetch --no-tags origin \
    "+refs/pull/$PR/head:$STAGE" >/dev/null 2>&1 \
    || die_infra pr-head-fetch-failed "could not fetch PR #$PR head"
FETCHED=$(git -C "$REPO" rev-parse --verify "$STAGE^{commit}" 2>/dev/null) \
    || die_infra pr-head-missing "fetched PR #$PR head is not a commit"
[ "$FETCHED" = "$ADVERTISED" ] \
    || die_infra pr-head-drift "PR #$PR moved from $ADVERTISED to $FETCHED during materialization"

# Creation, not replacement, makes the SHA-named ready ref immutable.  Another
# concurrent launcher may win the create; accepting it is safe only at the same SHA.
if ! git -C "$REPO" update-ref "$READY" "$ADVERTISED" "$ZERO" 2>/dev/null; then
    EXISTING=$(git -C "$REPO" rev-parse --verify "$READY^{commit}" 2>/dev/null || true)
    [ "$EXISTING" = "$ADVERTISED" ] \
        || die_infra pr-head-publish-failed "could not publish immutable head for PR #$PR"
fi
git -C "$REPO" cat-file -e "$ADVERTISED^{commit}" 2>/dev/null \
    || die_infra pr-head-missing "published PR #$PR head $ADVERTISED is missing"

printf '%s\n' "$ADVERTISED"
