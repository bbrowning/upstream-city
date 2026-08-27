#!/usr/bin/env bash
# Deterministically apply a lifecycle verdict: approve, revise, block, or escalate.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE="$SCRIPT_DIR/update-work-lifecycle.sh"
RIG="" WORK_BEAD="" INTENT="" ARTIFACT_ID="" HEAD_SHA="" BRANCH=""
REVISION="" MAX_ITERATIONS="" SYNTHESIS_FILE="" SETTLE_FILE="" FEEDBACK_BEAD=""
SYNTHESIS_BEAD="" SETTLEMENT_BEAD=""
REVISION_FORMULA="" REVISION_TARGET="" BASE="" BRANCH_PREFIX=""
IMPLEMENTER_TARGET="" REVIEWER_TARGET="" COORDINATOR_TARGET="" REVIEW_N="2"
LANE_A_TARGET="" LANE_B_TARGET=""

die() { printf '%s\n' "decide-change-lifecycle: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --rig) RIG="${2:?}"; shift 2 ;; --rig=*) RIG="${1#*=}"; shift ;;
    --work-bead) WORK_BEAD="${2:?}"; shift 2 ;; --work-bead=*) WORK_BEAD="${1#*=}"; shift ;;
    --intent) INTENT="${2:?}"; shift 2 ;; --intent=*) INTENT="${1#*=}"; shift ;;
    --artifact-id) ARTIFACT_ID="${2:?}"; shift 2 ;; --artifact-id=*) ARTIFACT_ID="${1#*=}"; shift ;;
    --head-sha) HEAD_SHA="${2:?}"; shift 2 ;; --head-sha=*) HEAD_SHA="${1#*=}"; shift ;;
    --branch) BRANCH="${2:?}"; shift 2 ;; --branch=*) BRANCH="${1#*=}"; shift ;;
    --revision) REVISION="${2:?}"; shift 2 ;; --revision=*) REVISION="${1#*=}"; shift ;;
    --max-iterations) MAX_ITERATIONS="${2:?}"; shift 2 ;; --max-iterations=*) MAX_ITERATIONS="${1#*=}"; shift ;;
    --synthesis-file) SYNTHESIS_FILE="${2:?}"; shift 2 ;; --synthesis-file=*) SYNTHESIS_FILE="${1#*=}"; shift ;;
    --settle-file) SETTLE_FILE="${2:?}"; shift 2 ;; --settle-file=*) SETTLE_FILE="${1#*=}"; shift ;;
    --feedback-bead) FEEDBACK_BEAD="${2:?}"; shift 2 ;; --feedback-bead=*) FEEDBACK_BEAD="${1#*=}"; shift ;;
    --synthesis-bead) SYNTHESIS_BEAD="${2:?}"; shift 2 ;; --synthesis-bead=*) SYNTHESIS_BEAD="${1#*=}"; shift ;;
    --settlement-bead) SETTLEMENT_BEAD="${2:?}"; shift 2 ;; --settlement-bead=*) SETTLEMENT_BEAD="${1#*=}"; shift ;;
    --revision-formula) REVISION_FORMULA="${2:?}"; shift 2 ;; --revision-formula=*) REVISION_FORMULA="${1#*=}"; shift ;;
    --revision-target) REVISION_TARGET="${2:?}"; shift 2 ;; --revision-target=*) REVISION_TARGET="${1#*=}"; shift ;;
    --base) BASE="${2:?}"; shift 2 ;; --base=*) BASE="${1#*=}"; shift ;;
    --branch-prefix) BRANCH_PREFIX="${2:?}"; shift 2 ;; --branch-prefix=*) BRANCH_PREFIX="${1#*=}"; shift ;;
    --implementer-target) IMPLEMENTER_TARGET="${2:?}"; shift 2 ;; --implementer-target=*) IMPLEMENTER_TARGET="${1#*=}"; shift ;;
    --reviewer-target) REVIEWER_TARGET="${2:?}"; shift 2 ;; --reviewer-target=*) REVIEWER_TARGET="${1#*=}"; shift ;;
    --coordinator-target) COORDINATOR_TARGET="${2:?}"; shift 2 ;; --coordinator-target=*) COORDINATOR_TARGET="${1#*=}"; shift ;;
    --review-n) REVIEW_N="${2:?}"; shift 2 ;; --review-n=*) REVIEW_N="${1#*=}"; shift ;;
    --lane-a-target) LANE_A_TARGET="${2:?}"; shift 2 ;; --lane-a-target=*) LANE_A_TARGET="${1#*=}"; shift ;;
    --lane-b-target) LANE_B_TARGET="${2:?}"; shift 2 ;; --lane-b-target=*) LANE_B_TARGET="${1#*=}"; shift ;;
    -*) die "unknown option '$1'" ;; *) die "unexpected argument '$1'" ;;
  esac
done

for pair in "rig:$RIG" "work-bead:$WORK_BEAD" "intent:$INTENT" "artifact-id:$ARTIFACT_ID" \
  "head-sha:$HEAD_SHA" "branch:$BRANCH" "revision:$REVISION" "max-iterations:$MAX_ITERATIONS" \
  "synthesis-file:$SYNTHESIS_FILE" "feedback-bead:$FEEDBACK_BEAD"; do
  [ -n "${pair#*:}" ] || die "--${pair%%:*} is required"
done
case "$INTENT" in feature|hard_bug) ;; *) die "--intent must be feature or hard_bug" ;; esac
case "$REVISION:$MAX_ITERATIONS" in *[!0-9:]*|:*|*:) die "revision bounds must be positive integers" ;; esac
[ "$REVISION" -ge 1 ] && [ "$MAX_ITERATIONS" -ge 1 ] || die "revision bounds must be positive integers"
[ -f "$SYNTHESIS_FILE" ] || die "synthesis file not found"

has_dispute=$(jq -r '.has_disputed_major // false' "$SYNTHESIS_FILE")
verdict=$(jq -er '.verdict' "$SYNTHESIS_FILE")
if [ "$has_dispute" = "true" ]; then
  [ -n "$SETTLE_FILE" ] && [ -f "$SETTLE_FILE" ] || die "disputed synthesis requires --settle-file"
  verdict=$(jq -er '.settled_verdict' "$SETTLE_FILE")
fi
case "$verdict" in approve|approve_with_nits|request_changes|blocked) ;; *) die "invalid effective verdict '$verdict'" ;; esac

common=(--city "$CITY" --rig "$RIG" --bead "$WORK_BEAD" --intent "$INTENT"
  --checkpoint review --iteration "$REVISION" --artifact-id "$ARTIFACT_ID"
  --head-sha "$HEAD_SHA" --branch "$BRANCH" --feedback-bead "$FEEDBACK_BEAD")

case "$verdict" in
  approve|approve_with_nits)
    "$UPDATE" "${common[@]}" --disposition approved --reason "$verdict"
    action=approved ;;
  request_changes)
    if [ "$REVISION" -ge "$MAX_ITERATIONS" ]; then
      "$UPDATE" "${common[@]}" --disposition escalated --reason revision-bound-exhausted
      evidence="$FEEDBACK_BEAD"
      [ -z "$SYNTHESIS_BEAD" ] || evidence="$evidence,$SYNTHESIS_BEAD"
      [ -z "$SETTLEMENT_BEAD" ] || evidence="$evidence,$SETTLEMENT_BEAD"
      bash "$SCRIPT_DIR/escalate-rig-work.sh" --rig "$RIG" --work-bead "$WORK_BEAD" \
        --workflow change-lifecycle --reason revision-bound-exhausted --phase review \
        --iteration "$REVISION" --branch "$BRANCH" --head-sha "$HEAD_SHA" \
        --artifact-id "$ARTIFACT_ID" --evidence-beads "$evidence" >/dev/null
      action=lead_escalated
    else
      for pair in "revision-formula:$REVISION_FORMULA" "revision-target:$REVISION_TARGET" "base:$BASE"; do
        [ -n "${pair#*:}" ] || die "request_changes requires --${pair%%:*}"
      done
      "$UPDATE" "${common[@]}" --disposition request_changes --reason request_changes
      next=$((REVISION + 1))
      set -- "$REVISION_TARGET" "$REVISION_FORMULA" --formula
      if [ "$INTENT" = "feature" ]; then
        set -- "$@" --var "work_bead=$WORK_BEAD" --var "base=$BASE" --var fetch_base=false
      else
        set -- "$@" --var "bug_bead=$WORK_BEAD" --var "base=$BASE" \
          --var "branch_prefix=$BRANCH_PREFIX" --var "implementer_target=$IMPLEMENTER_TARGET" \
          --var "reviewer_target=$REVIEWER_TARGET" --var "coordinator_target=$COORDINATOR_TARGET"
      fi
      set -- "$@" --var "revision=$next" --var "previous_artifact_id=$ARTIFACT_ID" \
        --var "feedback_bead=$FEEDBACK_BEAD" --var "producing_verdict=$verdict" \
        --var "review_n=$REVIEW_N" --var "max_review_iterations=$MAX_ITERATIONS" \
        --var "review_lane_a_target=$LANE_A_TARGET" --var "review_lane_b_target=$LANE_B_TARGET" \
        --title "$INTENT revision $next: $WORK_BEAD" --json
      "$GC" --city "$CITY" --rig "$RIG" sling "$@"
      action=revision_slung
    fi ;;
  blocked)
    "$UPDATE" "${common[@]}" --disposition blocked --reason review-blocked
    action=blocked ;;
esac

jq -cn --arg schema change-lifecycle-final.v1 --arg action "$action" --arg verdict "$verdict" \
  --arg work "$WORK_BEAD" --arg artifact "$ARTIFACT_ID" --arg head "$HEAD_SHA" \
  --arg branch "$BRANCH" --argjson revision "$REVISION" \
  '{schema:$schema,work_bead:$work,action:$action,effective_verdict:$verdict,
    artifact_id:$artifact,head_sha:$head,branch:$branch,revision:$revision,
    failure_class:"none",failure_reason:""}'
