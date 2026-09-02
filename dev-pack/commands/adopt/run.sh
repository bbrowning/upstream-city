#!/usr/bin/env bash
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZE="$SCRIPT_DIR/../../assets/scripts/normalize-pr-target.sh"
ENSURE_SOURCE="$SCRIPT_DIR/../../assets/scripts/ensure-review-source.sh"
PREPARE="$SCRIPT_DIR/../../assets/scripts/prepare-pr-adoption.sh"
POLICY="$SCRIPT_DIR/../../assets/workflow-policy.json"
VALIDATE_EXECUTION="$SCRIPT_DIR/../../assets/scripts/validate-execution-profile.py"

RIG=vllm RIG_EXPLICIT=0 SPEC="" STRATEGY=merge TASK="Resolve conflicts against the pinned target base and preserve the contributor's intended change."
OUTCOME=undecided PRESET=quality REVIEW_N=2 MAX_ITERATIONS=3 DRYRUN=0
EXECUTION=$(jq -er '.defaults.execution_profile' "$POLICY")

usage() { sed -n '1,80p' "$SCRIPT_DIR/help.md"; }
die() { printf 'adopt: %s\n' "$*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --rig) RIG="${2:?}"; RIG_EXPLICIT=1; shift 2 ;; --rig=*) RIG="${1#*=}"; RIG_EXPLICIT=1; shift ;;
    --strategy) STRATEGY="${2:?}"; shift 2 ;; --strategy=*) STRATEGY="${1#*=}"; shift ;;
    --task) TASK="${2:?}"; shift 2 ;; --task=*) TASK="${1#*=}"; shift ;;
    --outcome) OUTCOME="${2:?}"; shift 2 ;; --outcome=*) OUTCOME="${1#*=}"; shift ;;
    --quality) PRESET=quality; REVIEW_N=2; shift ;;
    --fast|--solo) PRESET=fast; REVIEW_N=1; shift ;;
    --execution) EXECUTION="${2:?}"; shift 2 ;; --execution=*) EXECUTION="${1#*=}"; shift ;;
    --max-review-iterations) MAX_ITERATIONS="${2:?}"; shift 2 ;; --max-review-iterations=*) MAX_ITERATIONS="${1#*=}"; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option '$1'" ;;
    *) [ -z "$SPEC" ] || die "unexpected argument '$1'"; SPEC="$1"; shift ;;
  esac
done
[ -n "$SPEC" ] || { usage >&2; die 'missing PR or PR-linked bead'; }
case "$STRATEGY" in merge|rebase) ;; *) die '--strategy must be merge or rebase' ;; esac
case "$OUTCOME" in undecided|update-original|request-author-apply|supersede) ;; *) die 'invalid --outcome' ;; esac
case "$MAX_ITERATIONS" in ''|*[!0-9]*) die '--max-review-iterations must be positive' ;; esac
[ "$MAX_ITERATIONS" -ge 1 ] || die '--max-review-iterations must be positive'

# Normalize rig#PR first. A remaining non-number is accepted only when it is a
# PR-linked human bead with external_ref=gh-N.
NORM_ARGS=(--rig "$RIG"); [ "$RIG_EXPLICIT" -eq 1 ] && NORM_ARGS+=(--rig-explicit)
NORM=$("$NORMALIZE" "$SPEC" "${NORM_ARGS[@]}") || exit $?
SPEC=$(printf '%s' "$NORM" | jq -r .spec); RIG=$(printf '%s' "$NORM" | jq -r .rig)
DECISION_BEAD=""
if [[ "$SPEC" =~ ^[0-9]+$ ]]; then
  PR="$SPEC"
else
  [[ "$SPEC" == *-* ]] || die "'$SPEC' is neither a PR number nor a PR-linked bead"
  if [ "$RIG_EXPLICIT" -eq 0 ]; then RIG="${SPEC%%-*}"; fi
  SHOWN=$("$GC" --city "$CITY" --rig "$RIG" bd show "$SPEC" --json 2>/dev/null) \
    || die "could not read PR-linked bead '$SPEC'"
  EXT=$(printf '%s' "$SHOWN" | jq -er '(if type=="array" then .[0] else . end).external_ref') \
    || die "bead '$SPEC' has no external_ref"
  [[ "$EXT" =~ ^gh-([0-9]+)$ ]] || die "bead '$SPEC' external_ref is not gh-N"
  PR="${BASH_REMATCH[1]}"; DECISION_BEAD="$SPEC"
fi

python3 "$VALIDATE_EXECUTION" --city "$CITY" --policy "$POLICY" --rig "$RIG" --profile "$EXECUTION" >/dev/null
IMPLEMENTER="$RIG/$(jq -er --arg p "$EXECUTION" '.execution_profiles[$p].roles.feature.implementer' "$POLICY")"
LANE_A="$RIG/$(jq -er --arg p "$EXECUTION" '.execution_profiles[$p].roles.review.lane_a' "$POLICY")"
LANE_B="$RIG/$(jq -er --arg p "$EXECUTION" '.execution_profiles[$p].roles.review.lane_b' "$POLICY")"
if [ "$DRYRUN" -eq 1 ]; then
  printf 'DRY RUN — would pin PR #%s head + freshly fetched target tip, create a separate internal adoption bead and durable branch, then sling pr-adopt (rig=%s, strategy=%s, outcome=%s, preset=%s, review_n=%s, implementer=%s, decision_bead=%s, remote_mutation=false)\n' \
    "$PR" "$RIG" "$STRATEGY" "$OUTCOME" "$PRESET" "$REVIEW_N" "$IMPLEMENTER" "${DECISION_BEAD:-auto}"
  exit 0
fi

RIGS=$("$GC" --city "$CITY" rig list --json) || die 'could not list rigs'
REPO=$(printf '%s' "$RIGS" | jq -er --arg r "$RIG" '.rigs[] | select(.name==$r) | .path') \
  || die "could not resolve rig '$RIG'"
[ -n "$DECISION_BEAD" ] || DECISION_BEAD=$("$ENSURE_SOURCE" --rig "$RIG" --pr "$PR") \
  || die 'could not establish the human disposition bead'

META=$(jq -cn --arg source "$DECISION_BEAD" --argjson pr "$PR" --arg strategy "$STRATEGY" --arg outcome "$OUTCOME" \
  '{"gc.workflow":"pr-adopt.v1","gc.human_source_bead":$source,"gc.source_pr":$pr,"gc.strategy":$strategy,"gc.recommended_upstream_action":$outcome}')
WORK_BEAD=$("$GC" --city "$CITY" --rig "$RIG" bd create "Adopt GitHub PR #$PR locally" \
  --type task --priority 2 --labels internal,pr-adoption --deps "discovered-from:$DECISION_BEAD" \
  --description "Internal local-only continuation of PR #$PR. Human disposition remains on $DECISION_BEAD. Task: $TASK" \
  --metadata "$META" --silent) || die 'could not create adoption tracking bead'
SAFE_BEAD=$(printf '%s' "$WORK_BEAD" | tr -cd 'A-Za-z0-9._-')
BRANCH="adopt/pr-$PR/$SAFE_BEAD"
DEST="${GC_MATERIALIZE_DIR:-$CITY/pr-worktrees}/$RIG/adopt-pr-$PR-$SAFE_BEAD"
if INPUT=$("$PREPARE" --repo "$REPO" --pr "$PR" --work-bead "$WORK_BEAD" --dest "$DEST" --branch "$BRANCH" --strategy "$STRATEGY"); then
  :
else
  rc=$?
  "$GC" --city "$CITY" --rig "$RIG" bd update "$WORK_BEAD" --status blocked --append-notes 'Materialization failed; no remote was mutated. Retry after resolving the reported fetch/permission/drift condition.' >/dev/null 2>&1 || true
  exit "$rc"
fi
SOURCE_HEAD=$(printf '%s' "$INPUT" | jq -r .source_head_sha)
TARGET_BASE=$(printf '%s' "$INPUT" | jq -r .target.sha)
BASE_REF=$(printf '%s' "$INPUT" | jq -r .target.ref)
ADOPTION_JSON=$(printf '%s' "$INPUT" | jq -c --arg decision "$DECISION_BEAD" --arg outcome "$OUTCOME" '. + {human_disposition_bead:$decision,recommended_upstream_action:$outcome}')
"$GC" --city "$CITY" --rig "$RIG" bd update "$WORK_BEAD" --status in_progress \
  --set-metadata "gc.pr_adoption_json=$ADOPTION_JSON" >/dev/null

set -- "$IMPLEMENTER" pr-adopt --formula \
  --var "work_bead=$WORK_BEAD" --var "human_disposition_bead=$DECISION_BEAD" --var "source_pr=$PR" \
  --var "source_head_sha=$SOURCE_HEAD" --var "target_base_sha=$TARGET_BASE" --var "target_base_ref=$BASE_REF" \
  --var "worktree=$DEST" --var "branch=$BRANCH" --var "strategy=$STRATEGY" --var "task=$TASK" \
  --var "recommended_upstream_action=$OUTCOME" --var revision=1 --var "review_n=$REVIEW_N" \
  --var "max_review_iterations=$MAX_ITERATIONS" --var "implementer_target=$IMPLEMENTER" \
  --var "review_lane_a_target=$LANE_A" --var "review_lane_b_target=$LANE_B" \
  --title "pr-adopt: #$PR ($WORK_BEAD)" --json
printf 'adopt: PR #%s pinned at %s onto %s (%s); durable branch %s; human decision %s remains open\n' \
  "$PR" "$SOURCE_HEAD" "$TARGET_BASE" "$BASE_REF" "$BRANCH" "$DECISION_BEAD" >&2
exec "$GC" --city "$CITY" --rig "$RIG" sling "$@"
