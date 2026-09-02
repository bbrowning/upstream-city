#!/usr/bin/env bash
# Resolve an implementation output and start the bounded local-change lifecycle.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$SCRIPT_DIR/resolve-local-change.sh"
RIG="" WORK_BEAD="" INTENT="" ARTIFACT="" N="2" MAX_ITERATIONS="3"
REVISION_FORMULA="" REVISION_TARGET="" BASE="" BRANCH_PREFIX=""
IMPLEMENTER_TARGET="" COORDINATOR_TARGET=""
LANE_A_TARGET="" LANE_B_TARGET="" ARBITER_TARGET=""
SOURCE_PR="" SOURCE_HEAD="" TARGET_BASE_REF="" WORKTREE="" STRATEGY="" TASK=""
HUMAN_DISPOSITION_BEAD="" RECOMMENDED_UPSTREAM_ACTION=""

die() { printf '%s\n' "sling-change-lifecycle: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --rig) RIG="${2:?}"; shift 2 ;; --rig=*) RIG="${1#*=}"; shift ;;
    --work-bead) WORK_BEAD="${2:?}"; shift 2 ;; --work-bead=*) WORK_BEAD="${1#*=}"; shift ;;
    --intent) INTENT="${2:?}"; shift 2 ;; --intent=*) INTENT="${1#*=}"; shift ;;
    --artifact) ARTIFACT="${2:?}"; shift 2 ;; --artifact=*) ARTIFACT="${1#*=}"; shift ;;
    --n) N="${2:?}"; shift 2 ;; --n=*) N="${1#*=}"; shift ;;
    --max-iterations) MAX_ITERATIONS="${2:?}"; shift 2 ;; --max-iterations=*) MAX_ITERATIONS="${1#*=}"; shift ;;
    --revision-formula) REVISION_FORMULA="${2:?}"; shift 2 ;; --revision-formula=*) REVISION_FORMULA="${1#*=}"; shift ;;
    --revision-target) REVISION_TARGET="${2:?}"; shift 2 ;; --revision-target=*) REVISION_TARGET="${1#*=}"; shift ;;
    --base) BASE="${2:?}"; shift 2 ;; --base=*) BASE="${1#*=}"; shift ;;
    --branch-prefix) BRANCH_PREFIX="${2:?}"; shift 2 ;; --branch-prefix=*) BRANCH_PREFIX="${1#*=}"; shift ;;
    --implementer-target) IMPLEMENTER_TARGET="${2:?}"; shift 2 ;; --implementer-target=*) IMPLEMENTER_TARGET="${1#*=}"; shift ;;
    --coordinator-target) COORDINATOR_TARGET="${2:?}"; shift 2 ;; --coordinator-target=*) COORDINATOR_TARGET="${1#*=}"; shift ;;
    --lane-a-target) LANE_A_TARGET="${2:?}"; shift 2 ;; --lane-a-target=*) LANE_A_TARGET="${1#*=}"; shift ;;
    --lane-b-target) LANE_B_TARGET="${2:?}"; shift 2 ;; --lane-b-target=*) LANE_B_TARGET="${1#*=}"; shift ;;
    --arbiter-target) ARBITER_TARGET="${2:?}"; shift 2 ;; --arbiter-target=*) ARBITER_TARGET="${1#*=}"; shift ;;
    --source-pr) SOURCE_PR="${2:?}"; shift 2 ;; --source-pr=*) SOURCE_PR="${1#*=}"; shift ;;
    --source-head) SOURCE_HEAD="${2:?}"; shift 2 ;; --source-head=*) SOURCE_HEAD="${1#*=}"; shift ;;
    --target-base-ref) TARGET_BASE_REF="${2:?}"; shift 2 ;; --target-base-ref=*) TARGET_BASE_REF="${1#*=}"; shift ;;
    --worktree) WORKTREE="${2:?}"; shift 2 ;; --worktree=*) WORKTREE="${1#*=}"; shift ;;
    --strategy) STRATEGY="${2:?}"; shift 2 ;; --strategy=*) STRATEGY="${1#*=}"; shift ;;
    --task) TASK="${2:?}"; shift 2 ;; --task=*) TASK="${1#*=}"; shift ;;
    --human-disposition-bead) HUMAN_DISPOSITION_BEAD="${2:?}"; shift 2 ;; --human-disposition-bead=*) HUMAN_DISPOSITION_BEAD="${1#*=}"; shift ;;
    --recommended-upstream-action) RECOMMENDED_UPSTREAM_ACTION="${2:?}"; shift 2 ;; --recommended-upstream-action=*) RECOMMENDED_UPSTREAM_ACTION="${1#*=}"; shift ;;
    -*) die "unknown option '$1'" ;; *) die "unexpected argument '$1'" ;;
  esac
done

for pair in "rig:$RIG" "work-bead:$WORK_BEAD" "intent:$INTENT" "artifact:$ARTIFACT" \
  "revision-formula:$REVISION_FORMULA" "revision-target:$REVISION_TARGET" "base:$BASE"; do
  [ -n "${pair#*:}" ] || die "--${pair%%:*} is required"
done
case "$INTENT" in feature|hard_bug|pr_adopt) ;; *) die "--intent must be feature, hard_bug, or pr_adopt" ;; esac
if [ "$INTENT" = pr_adopt ]; then
  for pair in "source-pr:$SOURCE_PR" "source-head:$SOURCE_HEAD" "target-base-ref:$TARGET_BASE_REF" \
    "worktree:$WORKTREE" "strategy:$STRATEGY" "task:$TASK" \
    "human-disposition-bead:$HUMAN_DISPOSITION_BEAD" "recommended-upstream-action:$RECOMMENDED_UPSTREAM_ACTION"; do
    [ -n "${pair#*:}" ] || die "pr_adopt requires --${pair%%:*}"
  done
fi
case "$N" in 1) FORMULA=change-lifecycle-solo ;; 2) FORMULA=change-lifecycle ;; *) die "--n must be 1 or 2" ;; esac
case "$MAX_ITERATIONS" in ''|*[!0-9]*) die "--max-iterations must be a positive integer" ;; esac
[ "$MAX_ITERATIONS" -ge 1 ] || die "--max-iterations must be a positive integer"
[ -n "$LANE_A_TARGET" ] || LANE_A_TARGET="$RIG/pr-reviewer-a-frontier-high"
[ -n "$LANE_B_TARGET" ] || LANE_B_TARGET="$RIG/pr-reviewer-b-frontier-high"
[ -n "$ARBITER_TARGET" ] || ARBITER_TARGET="$RIG/pr-arbiter"

RIGS_JSON=$("$GC" --city "$CITY" rig list --json) || die "could not list rigs"
REPO=$(printf '%s' "$RIGS_JSON" | jq -er --arg rig "$RIG" '.rigs[] | select(.name == $rig) | .path') \
  || die "could not resolve repository path for rig '$RIG'"
LOCAL=$("$RESOLVE" --repo "$REPO" --rig "$RIG" --artifact "$ARTIFACT") || exit $?

artifact_id=$(printf '%s' "$LOCAL" | jq -er '.artifact_id')
repository_id=$(printf '%s' "$LOCAL" | jq -er '.repository.id')
branch=$(printf '%s' "$LOCAL" | jq -er '.head.branch')
revision=$(printf '%s' "$LOCAL" | jq -er '.revision.number')
base_sha=$(printf '%s' "$LOCAL" | jq -er '.base.sha')
head_sha=$(printf '%s' "$LOCAL" | jq -er '.head.sha')

set -- "$RIG/pr-review-synthesizer" "$FORMULA" --formula \
  --var "work_bead=$WORK_BEAD" --var "intent_kind=$INTENT" \
  --var "implementation_artifact_ref=$ARTIFACT" --var "implementation_artifact_id=$artifact_id" \
  --var "implementation_repository_id=$repository_id" --var "implementation_branch=$branch" \
  --var "implementation_revision=$revision" --var "base_ref=$base_sha" --var "head_ref=$head_sha" \
  --var "max_iterations=$MAX_ITERATIONS" --var "revision_formula=$REVISION_FORMULA" \
  --var "revision_target=$REVISION_TARGET" --var "implementation_base=$BASE" \
  --var "branch_prefix=$BRANCH_PREFIX" --var "implementer_target=$IMPLEMENTER_TARGET" \
  --var "coordinator_target=$COORDINATOR_TARGET" \
  --var "source_pr=$SOURCE_PR" --var "source_head_sha=$SOURCE_HEAD" \
  --var "target_base_ref=$TARGET_BASE_REF" --var "worktree=$WORKTREE" --var "strategy=$STRATEGY" \
  --var "task=$TASK" --var "human_disposition_bead=$HUMAN_DISPOSITION_BEAD" \
  --var "recommended_upstream_action=$RECOMMENDED_UPSTREAM_ACTION" \
  --var "triage_target=$RIG/pr-triage" \
  --var "lane_a_target=$LANE_A_TARGET" --var "lane_b_target=$LANE_B_TARGET" \
  --var "synthesis_target=$RIG/pr-review-synthesizer" --var "arbiter_target=$ARBITER_TARGET" \
  --title "change lifecycle r$revision: $WORK_BEAD" --json

exec "$GC" --city "$CITY" --rig "$RIG" sling "$@"
