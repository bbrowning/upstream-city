#!/usr/bin/env bash
# Pin a GitHub PR head and target base, then create a durable local continuation.
set -euo pipefail

REPO="" PR="" WORK_BEAD="" DEST="" BRANCH="" STRATEGY="merge"
die() { printf 'prepare-pr-adoption: %s\n' "$*" >&2; exit 2; }
infra() { printf 'prepare-pr-adoption: infrastructure failure (%s): %s\n' "$1" "$2" >&2; exit 3; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?}"; shift 2 ;; --repo=*) REPO="${1#*=}"; shift ;;
    --pr) PR="${2:?}"; shift 2 ;; --pr=*) PR="${1#*=}"; shift ;;
    --work-bead) WORK_BEAD="${2:?}"; shift 2 ;; --work-bead=*) WORK_BEAD="${1#*=}"; shift ;;
    --dest) DEST="${2:?}"; shift 2 ;; --dest=*) DEST="${1#*=}"; shift ;;
    --branch) BRANCH="${2:?}"; shift 2 ;; --branch=*) BRANCH="${1#*=}"; shift ;;
    --strategy) STRATEGY="${2:?}"; shift 2 ;; --strategy=*) STRATEGY="${1#*=}"; shift ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[ -n "$REPO" ] && [ -n "$WORK_BEAD" ] && [ -n "$DEST" ] && [ -n "$BRANCH" ] && [[ "$PR" =~ ^[0-9]+$ ]] \
  || die 'required: --repo PATH --pr N --work-bead ID --dest PATH --branch NAME'
case "$STRATEGY" in merge|rebase) ;; *) die '--strategy must be merge or rebase' ;; esac
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || infra repository-unavailable "$REPO is not a git worktree"
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || die "invalid branch '$BRANCH'"
command -v gh >/dev/null 2>&1 || infra metadata-unavailable 'gh is not installed'

META=$(cd "$REPO" && gh api "repos/{owner}/{repo}/pulls/$PR" 2>/dev/null) \
  || infra metadata-unavailable "could not resolve PR #$PR"
HEAD_SHA=$(printf '%s' "$META" | jq -er '.head.sha') || infra metadata-invalid 'missing head SHA'
ADVERTISED_BASE_SHA=$(printf '%s' "$META" | jq -er '.base.sha') || infra metadata-invalid 'missing base SHA'
BASE_REF=$(printf '%s' "$META" | jq -er '.base.ref') || infra metadata-invalid 'missing base ref'
HEAD_REPO=$(printf '%s' "$META" | jq -r '.head.repo.full_name // ""')
HEAD_BRANCH=$(printf '%s' "$META" | jq -r '.head.ref // ""')
AUTHOR=$(printf '%s' "$META" | jq -r '.user.login // "unknown"')
URL=$(printf '%s' "$META" | jq -r '.html_url // ""')
FORMAT=$(git -C "$REPO" rev-parse --show-object-format 2>/dev/null || printf sha1)
case "$FORMAT:$HEAD_SHA:$ADVERTISED_BASE_SHA" in
  sha1:????????????????????????????????????????:????????????????????????????????????????|sha256:????????????????????????????????????????????????????????????????:????????????????????????????????????????????????????????????????) ;;
  *) infra metadata-invalid "invalid $FORMAT head or base object id" ;;
esac

STAGE_HEAD="refs/gc/pr-adopt-staging/$PR/head/$$"
STAGE_BASE="refs/gc/pr-adopt-staging/$PR/base/$$"
READY_HEAD="refs/gc/pr-heads/$PR/$HEAD_SHA"
cleanup() {
  git -C "$REPO" update-ref -d "$STAGE_HEAD" >/dev/null 2>&1 || true
  git -C "$REPO" update-ref -d "$STAGE_BASE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
GIT_LFS_SKIP_SMUDGE=1 git -C "$REPO" fetch --no-tags origin \
  "+refs/pull/$PR/head:$STAGE_HEAD" "+refs/heads/$BASE_REF:$STAGE_BASE" >/dev/null 2>&1 \
  || infra fetch-failed "could not fetch PR #$PR and target branch $BASE_REF"
FETCHED_HEAD=$(git -C "$REPO" rev-parse "$STAGE_HEAD^{commit}")
FETCHED_BASE=$(git -C "$REPO" rev-parse "$STAGE_BASE^{commit}")
READY_BASE="refs/gc/pr-bases/$PR/$FETCHED_BASE"
[ "$FETCHED_HEAD" = "$HEAD_SHA" ] || infra moved-head "PR #$PR moved from $HEAD_SHA to $FETCHED_HEAD"
git -C "$REPO" cat-file -e "$ADVERTISED_BASE_SHA^{commit}" 2>/dev/null \
  || infra advertised-base-missing "target advertised $ADVERTISED_BASE_SHA but fetched $BASE_REF at $FETCHED_BASE without that object"
git -C "$REPO" merge-base --is-ancestor "$ADVERTISED_BASE_SHA" "$FETCHED_BASE" \
  || infra target-history-rewritten "target $BASE_REF no longer contains advertised base $ADVERTISED_BASE_SHA (fetched $FETCHED_BASE)"
git -C "$REPO" update-ref "$READY_HEAD" "$HEAD_SHA"
git -C "$REPO" update-ref "$READY_BASE" "$FETCHED_BASE"

if [ -e "$DEST" ]; then
  [ -e "$DEST/.git" ] || die "destination exists but is not a worktree: $DEST"
  actual_branch=$(git -C "$DEST" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$actual_branch" = "$BRANCH" ] || die "destination is on '$actual_branch', expected '$BRANCH'"
  actual_source=$(git -C "$DEST" config --get gc.prAdopt.sourceHead || true)
  actual_base=$(git -C "$DEST" config --get gc.prAdopt.targetBase || true)
  [ "$actual_source:$actual_base" = "$HEAD_SHA:$FETCHED_BASE" ] \
    || die 'existing continuation pins differ; start a new adoption instead of overwriting it'
else
  git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" \
    && die "branch already exists without its durable worktree: $BRANCH"
  mkdir -p "$(dirname "$DEST")"
  GIT_LFS_SKIP_SMUDGE=1 git -C "$REPO" worktree add -b "$BRANCH" "$DEST" "$HEAD_SHA" 1>&2
fi

mkdir -p "$DEST/.beads"
printf '%s\n' "$REPO/.beads" > "$DEST/.beads/redirect"
git -C "$DEST" config gc.prAdopt.sourcePr "$PR"
git -C "$DEST" config gc.prAdopt.sourceHead "$HEAD_SHA"
git -C "$DEST" config gc.prAdopt.targetBase "$FETCHED_BASE"
git -C "$DEST" config gc.prAdopt.strategy "$STRATEGY"

jq -cn --arg schema pr-adoption-input.v1 --argjson pr "$PR" --arg url "$URL" \
  --arg author "$AUTHOR" --arg head_repo "$HEAD_REPO" --arg head_branch "$HEAD_BRANCH" \
  --arg source_head "$HEAD_SHA" --arg base_ref "$BASE_REF" --arg target_base "$FETCHED_BASE" \
  --arg advertised_base "$ADVERTISED_BASE_SHA" \
  --arg ready_head "$READY_HEAD" --arg ready_base "$READY_BASE" --arg work_bead "$WORK_BEAD" \
  --arg worktree "$DEST" --arg branch "$BRANCH" --arg strategy "$STRATEGY" \
  '{schema:$schema,source_pr:$pr,source_url:$url,original_author:$author,
    contributor:{repository:$head_repo,branch:$head_branch},source_head_sha:$source_head,
    target:{ref:$base_ref,sha:$target_base,advertised_sha:$advertised_base},materialized_refs:{head:$ready_head,base:$ready_base},
    work_bead:$work_bead,worktree:$worktree,branch:$branch,strategy:$strategy}'
