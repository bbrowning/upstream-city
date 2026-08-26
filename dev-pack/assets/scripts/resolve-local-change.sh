#!/usr/bin/env bash
# Resolve and validate a local-change artifact (file or bead), or an explicit local ref.
set -euo pipefail

GC="${GC_BIN:-gc}" ; CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE_COMMITS="$SCRIPT_DIR/validate-commit-series.py"
REPO="." ; RIG="" ; ARTIFACT="" ; HEAD="" ; BASE="origin/main"
die() { printf '%s\n' "resolve-local-change: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:?}"; shift 2 ;; --repo=*) REPO="${1#*=}"; shift ;;
        --rig) RIG="${2:?}"; shift 2 ;; --rig=*) RIG="${1#*=}"; shift ;;
        --artifact) ARTIFACT="${2:?}"; shift 2 ;; --artifact=*) ARTIFACT="${1#*=}"; shift ;;
        --head) HEAD="${2:?}"; shift 2 ;; --head=*) HEAD="${1#*=}"; shift ;;
        --base) BASE="${2:?}"; shift 2 ;; --base=*) BASE="${1#*=}"; shift ;;
        -*) die "unknown option '$1'" ;; *) die "unexpected argument '$1'" ;;
    esac
done
[ -n "$RIG" ] || die "--rig is required"
if [ -n "$ARTIFACT" ] && [ -n "$HEAD" ]; then die "use either --artifact or --head"; fi
[ -n "$ARTIFACT$HEAD" ] || die "--artifact or --head is required"
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "rig repository is not a git worktree: $REPO"

COMMON_RAW=$(git -C "$REPO" rev-parse --git-common-dir)
case "$COMMON_RAW" in /*) COMMON_DIR=$(realpath "$COMMON_RAW") ;; *) COMMON_DIR=$(realpath "$REPO/$COMMON_RAW") ;; esac
OBJECT_FORMAT=$(git -C "$REPO" rev-parse --show-object-format 2>/dev/null || printf sha1)
REPOSITORY_ID=$(printf '%s\0%s' "$OBJECT_FORMAT" "$COMMON_DIR" | sha256sum | awk '{print $1}')

if [ -z "$ARTIFACT" ]; then
    BASE_SHA=$(git -C "$REPO" rev-parse --verify "$BASE^{commit}" 2>/dev/null) || die "missing local base ref: $BASE"
    HEAD_SHA=$(git -C "$REPO" rev-parse --verify "$HEAD^{commit}" 2>/dev/null) || die "missing local head ref: $HEAD"
    git -C "$REPO" merge-base --is-ancestor "$BASE_SHA" "$HEAD_SHA" || die "base is not an ancestor of head"
    BRANCH=""
    if git -C "$REPO" show-ref --verify --quiet "refs/heads/$HEAD"; then BRANCH="$HEAD"; fi
    jq -S -cn --arg rig "$RIG" --arg repo "$REPOSITORY_ID" --arg common "$COMMON_DIR" --arg fmt "$OBJECT_FORMAT" \
        --arg base_ref "$BASE" --arg base_sha "$BASE_SHA" --arg branch "$BRANCH" --arg head_sha "$HEAD_SHA" \
        '{schema:"local-change.v1",artifact_id:"explicit-local-ref",producer:{rig:$rig,workflow:"explicit-review",bead:"",intent_kind:"explicit"},repository:{id:$repo,git_common_dir:$common,object_format:$fmt},base:{ref:$base_ref,sha:$base_sha},head:{branch:$branch,sha:$head_sha},revision:{number:0,lineage:{previous_artifact_id:null,producing_feedback:null}}}'
    exit 0
fi

if [ -f "$ARTIFACT" ]; then RAW=$(jq -ce . "$ARTIFACT") || die "artifact file is not valid JSON: $ARTIFACT"
else
    SHOWN=$("$GC" --city "$CITY" --rig "$RIG" bd show "$ARTIFACT" --json 2>/dev/null) \
        || die "artifact bead '$ARTIFACT' is missing in rig '$RIG'"
    RAW=$(printf '%s' "$SHOWN" | jq -cer '(if type == "array" then .[0] else . end).metadata["gc.output_json"] | if type == "string" then fromjson else . end') \
        || die "bead '$ARTIFACT' has no valid gc.output_json artifact"
fi
CHANGE=$(printf '%s' "$RAW" | jq -ce '.local_change // .') || die "could not read local change"
printf '%s' "$CHANGE" | jq -e '
    .schema == "local-change.v1" and (.artifact_id|type=="string") and
    (.producer.rig|type=="string") and (.repository.id|type=="string") and
    (.base.sha|test("^[0-9a-f]{40,64}$")) and (.head.sha|test("^[0-9a-f]{40,64}$")) and
    (.head.branch|type=="string") and (.revision.number|type=="number")' >/dev/null \
    || die "artifact does not satisfy local-change.v1"

ART_RIG=$(printf '%s' "$CHANGE" | jq -r '.producer.rig')
[ "$ART_RIG" = "$RIG" ] || die "cross-rig artifact: produced for '$ART_RIG', review requested in '$RIG'"
ART_REPO=$(printf '%s' "$CHANGE" | jq -r '.repository.id')
[ "$ART_REPO" = "$REPOSITORY_ID" ] || die "repository mismatch: artifact does not belong to rig '$RIG' repository"
BODY=$(printf '%s' "$CHANGE" | jq -S -c 'del(.artifact_id)')
EXPECTED_ID=$(printf '%s' "$BODY" | sha256sum | awk '{print $1}')
[ "$(printf '%s' "$CHANGE" | jq -r '.artifact_id')" = "$EXPECTED_ID" ] || die "artifact integrity check failed"

BASE_SHA=$(printf '%s' "$CHANGE" | jq -r '.base.sha')
HEAD_SHA=$(printf '%s' "$CHANGE" | jq -r '.head.sha')
BRANCH=$(printf '%s' "$CHANGE" | jq -r '.head.branch')
git -C "$REPO" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null || die "recorded base commit is missing locally: $BASE_SHA"
git -C "$REPO" cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null || die "recorded head commit is missing locally: $HEAD_SHA"
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || die "artifact contains invalid branch: $BRANCH"
ACTUAL_HEAD=$(git -C "$REPO" rev-parse --verify "refs/heads/$BRANCH^{commit}" 2>/dev/null) || die "recorded local branch is missing: $BRANCH"
[ "$ACTUAL_HEAD" = "$HEAD_SHA" ] || die "stale artifact: branch '$BRANCH' points to $ACTUAL_HEAD, recorded head is $HEAD_SHA"
git -C "$REPO" merge-base --is-ancestor "$BASE_SHA" "$HEAD_SHA" || die "recorded base is not an ancestor of recorded head"

if printf '%s' "$CHANGE" | jq -e '.commit_message_quality != null' >/dev/null; then
    [ -x "$VALIDATE_COMMITS" ] || die "commit-series validator not found/executable: $VALIDATE_COMMITS"
    QUALITY_TMP=$(mktemp)
    trap 'rm -f "$QUALITY_TMP"' EXIT
    "$VALIDATE_COMMITS" --repo "$REPO" --base "$BASE_SHA" --head "$HEAD_SHA" --output "$QUALITY_TMP" \
        || die "commit message quality gate failed while resolving artifact"
    QUALITY=$(jq -ce . "$QUALITY_TMP") || die "commit message validator emitted invalid JSON"
    rm -f "$QUALITY_TMP"
    trap - EXIT
    COMMITS=$(printf '%s' "$QUALITY" | jq -c '.commits')
    QUALITY_AUDIT=$(printf '%s' "$QUALITY" | jq -S -c '{schema,policy,valid,violations}')
    [ "$(printf '%s' "$CHANGE" | jq -S -c '.commit_message_quality')" = "$QUALITY_AUDIT" ] \
        || die "artifact commit-message policy evidence does not match its immutable range"
else
    COMMITS=$(git -C "$REPO" log --reverse --format='%H%x09%s' "$BASE_SHA..$HEAD_SHA" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {sha:.[0], subject:(.[1:] | join("\t"))})')
fi
PATHS=$(git -C "$REPO" diff --name-only "$BASE_SHA...$HEAD_SHA" | jq -R -s -c 'split("\n") | map(select(length > 0))')
[ "$(printf '%s' "$CHANGE" | jq -S -c '.commits')" = "$(printf '%s' "$COMMITS" | jq -S -c .)" ] || die "artifact commit list does not match its immutable range"
[ "$(printf '%s' "$CHANGE" | jq -S -c '.changed_paths')" = "$(printf '%s' "$PATHS" | jq -S -c .)" ] || die "artifact changed paths do not match its immutable range"
printf '%s\n' "$CHANGE"
