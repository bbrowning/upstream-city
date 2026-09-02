#!/usr/bin/env bash
# Record the parent feature/bug lifecycle and close it only at an approved checkpoint.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="" ; RIG="" ; BEAD="" ; INTENT="" ; CHECKPOINT="" ; DISPOSITION=""
ITERATION="0" ; ARTIFACT_ID="" ; HEAD_SHA="" ; BRANCH="" ; FEEDBACK_BEAD="" ; REASON=""

die() { printf '%s\n' "update-work-lifecycle: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --city) CITY="${2:?}"; shift 2 ;; --city=*) CITY="${1#*=}"; shift ;;
        --rig) RIG="${2:?}"; shift 2 ;; --rig=*) RIG="${1#*=}"; shift ;;
        --bead) BEAD="${2:?}"; shift 2 ;; --bead=*) BEAD="${1#*=}"; shift ;;
        --intent) INTENT="${2:?}"; shift 2 ;; --intent=*) INTENT="${1#*=}"; shift ;;
        --checkpoint) CHECKPOINT="${2:?}"; shift 2 ;; --checkpoint=*) CHECKPOINT="${1#*=}"; shift ;;
        --disposition) DISPOSITION="${2:?}"; shift 2 ;; --disposition=*) DISPOSITION="${1#*=}"; shift ;;
        --iteration) ITERATION="${2:?}"; shift 2 ;; --iteration=*) ITERATION="${1#*=}"; shift ;;
        --artifact-id) ARTIFACT_ID="${2:?}"; shift 2 ;; --artifact-id=*) ARTIFACT_ID="${1#*=}"; shift ;;
        --head-sha) HEAD_SHA="${2:?}"; shift 2 ;; --head-sha=*) HEAD_SHA="${1#*=}"; shift ;;
        --branch) BRANCH="${2:?}"; shift 2 ;; --branch=*) BRANCH="${1#*=}"; shift ;;
        --feedback-bead) FEEDBACK_BEAD="${2:?}"; shift 2 ;; --feedback-bead=*) FEEDBACK_BEAD="${1#*=}"; shift ;;
        --reason) REASON="${2:?}"; shift 2 ;; --reason=*) REASON="${1#*=}"; shift ;;
        -*) die "unknown option '$1'" ;; *) die "unexpected argument '$1'" ;;
    esac
done

[ -n "$BEAD" ] && [ -n "$INTENT" ] && [ -n "$CHECKPOINT" ] && [ -n "$DISPOSITION" ] \
    || die "--bead, --intent, --checkpoint, and --disposition are required"
case "$INTENT" in feature|hard_bug|pr_adopt) ;; *) die "--intent must be feature, hard_bug, or pr_adopt" ;; esac
case "$DISPOSITION" in implementing|awaiting_review|settling|request_changes|blocked|escalated|approved) ;;
    *) die "invalid --disposition '$DISPOSITION'" ;;
esac
case "$ITERATION" in ''|*[!0-9]*) die "--iteration must be a non-negative integer" ;; esac
if [ "$DISPOSITION" = "approved" ]; then
    [ -n "$ARTIFACT_ID" ] && [ -n "$HEAD_SHA" ] && [ -n "$BRANCH" ] \
        || die "approved disposition requires --artifact-id, --head-sha, and --branch"
fi

gc_cmd=("$GC")
[ -z "$CITY" ] || gc_cmd+=(--city "$CITY")
[ -z "$RIG" ] || gc_cmd+=(--rig "$RIG")

raw=$("${gc_cmd[@]}" bd show "$BEAD" --json) || die "could not read parent work bead $BEAD"
status=$(printf '%s' "$raw" | jq -er '(if type == "array" then .[0] else . end).status') \
    || die "parent work bead $BEAD has no status"
existing=$(printf '%s' "$raw" | jq -r '(if type == "array" then .[0] else . end).metadata["gc.lifecycle_json"] // empty')

if [ "$status" = "closed" ]; then
    if [ "$DISPOSITION" = "approved" ] && [ -n "$existing" ] && printf '%s' "$existing" | jq -e \
        --arg artifact "$ARTIFACT_ID" --arg head "$HEAD_SHA" --arg branch "$BRANCH" \
        '.schema == "work-lifecycle.v1" and .disposition == "approved" and
         .artifact_id == $artifact and .head_sha == $head and .branch == $branch' >/dev/null; then
        exit 0
    fi
    die "parent work bead $BEAD is already closed at a different lifecycle checkpoint"
fi

updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
lifecycle=$(jq -cn --arg schema work-lifecycle.v1 --arg intent "$INTENT" \
    --arg checkpoint "$CHECKPOINT" --arg disposition "$DISPOSITION" \
    --argjson iteration "$ITERATION" --arg artifact "$ARTIFACT_ID" --arg head "$HEAD_SHA" \
    --arg branch "$BRANCH" --arg feedback "$FEEDBACK_BEAD" --arg reason "$REASON" --arg updated "$updated_at" \
    '{schema:$schema,intent_kind:$intent,checkpoint:$checkpoint,disposition:$disposition,
      iteration:$iteration,artifact_id:(if $artifact=="" then null else $artifact end),
      head_sha:(if $head=="" then null else $head end),branch:(if $branch=="" then null else $branch end),
      feedback_bead:(if $feedback=="" then null else $feedback end),reason:$reason,updated_at:$updated}')

"${gc_cmd[@]}" bd update "$BEAD" --status in_progress --set-metadata "gc.lifecycle_json=$lifecycle" >/dev/null
stored=$("${gc_cmd[@]}" bd show "$BEAD" --json) || die "could not verify lifecycle state for $BEAD"
stored_lifecycle=$(printf '%s' "$stored" | jq -r '(if type == "array" then .[0] else . end).metadata["gc.lifecycle_json"] // empty')
[ "$(printf '%s' "$stored_lifecycle" | jq -S -c .)" = "$(printf '%s' "$lifecycle" | jq -S -c .)" ] \
    || die "stored lifecycle state does not match checkpoint for $BEAD"

[ "$DISPOSITION" = "approved" ] || exit 0
"${gc_cmd[@]}" bd close "$BEAD" --reason "lifecycle approved: $REASON ($BRANCH @ $HEAD_SHA)" >/dev/null
