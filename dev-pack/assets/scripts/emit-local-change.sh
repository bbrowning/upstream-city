#!/usr/bin/env bash
# Build a canonical, immutable local-change.v1 artifact from committed git state.
set -euo pipefail

REPO="." ; RIG="" ; WORKFLOW="" ; BEAD="" ; INTENT="" ; BASE="" ; BRANCH=""
VERIFY_FILE="" ; OUTPUT="" ; REVISION="1" ; PREVIOUS="" ; FEEDBACK_BEAD="" ; VERDICT=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE_COMMITS="$SCRIPT_DIR/validate-commit-series.py"

die() { printf '%s\n' "emit-local-change: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:?}"; shift 2 ;; --repo=*) REPO="${1#*=}"; shift ;;
        --rig) RIG="${2:?}"; shift 2 ;; --rig=*) RIG="${1#*=}"; shift ;;
        --workflow) WORKFLOW="${2:?}"; shift 2 ;; --workflow=*) WORKFLOW="${1#*=}"; shift ;;
        --bead) BEAD="${2:?}"; shift 2 ;; --bead=*) BEAD="${1#*=}"; shift ;;
        --intent) INTENT="${2:?}"; shift 2 ;; --intent=*) INTENT="${1#*=}"; shift ;;
        --base) BASE="${2:?}"; shift 2 ;; --base=*) BASE="${1#*=}"; shift ;;
        --branch) BRANCH="${2:?}"; shift 2 ;; --branch=*) BRANCH="${1#*=}"; shift ;;
        --verification-file) VERIFY_FILE="${2:?}"; shift 2 ;; --verification-file=*) VERIFY_FILE="${1#*=}"; shift ;;
        --output) OUTPUT="${2:?}"; shift 2 ;; --output=*) OUTPUT="${1#*=}"; shift ;;
        --revision) REVISION="${2:?}"; shift 2 ;; --revision=*) REVISION="${1#*=}"; shift ;;
        --previous-artifact) PREVIOUS="${2:?}"; shift 2 ;; --previous-artifact=*) PREVIOUS="${1#*=}"; shift ;;
        --feedback-bead) FEEDBACK_BEAD="${2:?}"; shift 2 ;; --feedback-bead=*) FEEDBACK_BEAD="${1#*=}"; shift ;;
        --verdict) VERDICT="${2:?}"; shift 2 ;; --verdict=*) VERDICT="${1#*=}"; shift ;;
        -*) die "unknown option '$1'" ;; *) die "unexpected argument '$1'" ;;
    esac
done

for pair in "rig:$RIG" "workflow:$WORKFLOW" "bead:$BEAD" "intent:$INTENT" "base:$BASE" "branch:$BRANCH" "output:$OUTPUT"; do
    [ -n "${pair#*:}" ] || die "--${pair%%:*} is required"
done
case "$INTENT" in feature|hard_bug) ;; *) die "--intent must be feature or hard_bug" ;; esac
case "$REVISION" in ''|*[!0-9]*) die "--revision must be a positive integer" ;; esac
[ "$REVISION" -ge 1 ] || die "--revision must be a positive integer"
if [ "$REVISION" -eq 1 ]; then
    [ -z "$PREVIOUS$FEEDBACK_BEAD$VERDICT" ] || die "revision 1 cannot name prior review lineage"
else
    [ -n "$PREVIOUS" ] && [ -n "$FEEDBACK_BEAD" ] && [ -n "$VERDICT" ] \
        || die "revision $REVISION requires --previous-artifact, --feedback-bead, and --verdict"
fi
[ -z "$VERIFY_FILE" ] || [ -f "$VERIFY_FILE" ] || die "verification file not found: $VERIFY_FILE"
VERIFY='[]'
[ -z "$VERIFY_FILE" ] || VERIFY=$(jq -ce 'if type == "array" then . else error("verification must be an array") end' "$VERIFY_FILE")

git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git worktree: $REPO"
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || die "invalid local branch: $BRANCH"
BASE_SHA=$(git -C "$REPO" rev-parse --verify "$BASE^{commit}" 2>/dev/null) || die "missing local base ref: $BASE"
HEAD_SHA=$(git -C "$REPO" rev-parse --verify "refs/heads/$BRANCH^{commit}" 2>/dev/null) || die "missing local branch: $BRANCH"
[ "$(git -C "$REPO" rev-parse HEAD)" = "$HEAD_SHA" ] || die "HEAD is not the recorded branch tip: $BRANCH"
git -C "$REPO" merge-base --is-ancestor "$BASE_SHA" "$HEAD_SHA" || die "base is not an ancestor of head"

COMMON_RAW=$(git -C "$REPO" rev-parse --git-common-dir)
case "$COMMON_RAW" in /*) COMMON_DIR=$(realpath "$COMMON_RAW") ;; *) COMMON_DIR=$(realpath "$REPO/$COMMON_RAW") ;; esac
WORKTREE=$(realpath "$(git -C "$REPO" rev-parse --show-toplevel)")
OBJECT_FORMAT=$(git -C "$REPO" rev-parse --show-object-format 2>/dev/null || printf sha1)
REPOSITORY_ID=$(printf '%s\0%s' "$OBJECT_FORMAT" "$COMMON_DIR" | sha256sum | awk '{print $1}')
[ -x "$VALIDATE_COMMITS" ] || die "commit-series validator not found/executable: $VALIDATE_COMMITS"
QUALITY_TMP=$(mktemp)
trap 'rm -f "$QUALITY_TMP"' EXIT
if ! "$VALIDATE_COMMITS" --repo "$REPO" --base "$BASE_SHA" --head "$HEAD_SHA" --output "$QUALITY_TMP"; then
    die "commit message quality gate failed for $BASE_SHA..$HEAD_SHA"
fi
QUALITY=$(jq -ce . "$QUALITY_TMP") || die "commit message validator emitted invalid JSON"
rm -f "$QUALITY_TMP"
trap - EXIT
COMMITS=$(printf '%s' "$QUALITY" | jq -c '.commits')
QUALITY_AUDIT=$(printf '%s' "$QUALITY" | jq -c '{schema,policy,valid,violations}')
PATHS=$(git -C "$REPO" diff --name-only "$BASE_SHA...$HEAD_SHA" | jq -R -s -c 'split("\n") | map(select(length > 0))')
[ "$COMMITS" != '[]' ] || die "local change has no commits after its base"
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ "$REVISION" -eq 1 ]; then LINEAGE='{"previous_artifact_id":null,"producing_feedback":null}'
else
    LINEAGE=$(jq -cn --arg previous "$PREVIOUS" --arg bead "$FEEDBACK_BEAD" --arg verdict "$VERDICT" \
        '{previous_artifact_id:$previous,producing_feedback:{bead:$bead,verdict:$verdict}}')
fi

BODY=$(jq -S -cn \
    --arg schema local-change.v1 --arg rig "$RIG" --arg workflow "$WORKFLOW" --arg bead "$BEAD" --arg intent "$INTENT" \
    --arg repo_id "$REPOSITORY_ID" --arg common "$COMMON_DIR" --arg object_format "$OBJECT_FORMAT" --arg worktree "$WORKTREE" \
    --arg base_ref "$BASE" --arg base_sha "$BASE_SHA" --arg branch "$BRANCH" --arg head_sha "$HEAD_SHA" \
    --argjson commits "$COMMITS" --argjson commit_quality "$QUALITY_AUDIT" --argjson paths "$PATHS" --argjson verification "$VERIFY" \
    --arg created "$CREATED_AT" --arg generator dev-pack/emit-local-change.sh --argjson revision "$REVISION" --argjson lineage "$LINEAGE" \
    '{schema:$schema,producer:{rig:$rig,workflow:$workflow,bead:$bead,intent_kind:$intent},repository:{id:$repo_id,git_common_dir:$common,object_format:$object_format},worktree:{path:$worktree},base:{ref:$base_ref,sha:$base_sha},head:{branch:$branch,sha:$head_sha},commits:$commits,commit_message_quality:$commit_quality,changed_paths:$paths,verification:$verification,provenance:{created_at:$created,generator:$generator},revision:{number:$revision,lineage:$lineage}}')
ARTIFACT_ID=$(printf '%s' "$BODY" | sha256sum | awk '{print $1}')
FINAL=$(printf '%s' "$BODY" | jq -S -c --arg id "$ARTIFACT_ID" '. + {artifact_id:$id}')

OUT_DIR=$(dirname "$OUTPUT")
[ -d "$OUT_DIR" ] || die "output directory does not exist: $OUT_DIR"
TMP=$(mktemp "$OUT_DIR/.local-change.XXXXXX")
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$FINAL" > "$TMP"
chmod 0444 "$TMP"
mv "$TMP" "$OUTPUT"
trap - EXIT
