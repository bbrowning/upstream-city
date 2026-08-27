#!/usr/bin/env bash
# feature — kick off a single-lane feature implementation without hand-typing the sling.
#
#   gc dev-pack feature <bead> [options]
#
# Resolves the RIG (explicit --rig wins, else inferred from the bead prefix, e.g.
# vllm-123 -> vllm), then slings the feature-dev formula to the resolved semantic
# implementation target, which
# implements and commits the assignment on a local paude/<bead> branch in its own
# worktree. The operator exports the commit; the arc closes on a real checkpoint.
#
# Env (provided by gc): GC_CITY_PATH, GC_BIN.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="$SCRIPT_DIR/../../assets/workflow-policy.json"
VALIDATE_EXECUTION="$SCRIPT_DIR/../../assets/scripts/validate-execution-profile.py"
[ -r "$POLICY" ] || { printf '%s\n' "feature: workflow policy not found: $POLICY" >&2; exit 2; }

RIG="" ; BASE="$(jq -er '.defaults.base_ref' "$POLICY")" ; BEAD="" ; DRYRUN="no" ; FETCH_BASE="true"
REVISION="1" ; PREVIOUS_ARTIFACT="" ; FEEDBACK_BEAD="" ; PRODUCING_VERDICT=""
REVIEW_N="$(jq -er '.presets.quality.feature.review_n' "$POLICY")"
MAX_REVIEW_ITERATIONS="$(jq -er '.defaults.max_review_iterations' "$POLICY")"
REVIEW_LANE_A="" ; REVIEW_LANE_B=""
REVIEW_LANES_SET="false" ; REVIEW_N_SET="false" ; PRESET="quality"
EXECUTION="$(jq -er '.defaults.execution_profile' "$POLICY")" ; IMPLEMENTER_TARGET=""

usage() {
    cat <<'EOF'
usage: gc dev-pack feature <bead> [options]

Resolve the rig (--rig, else inferred from the bead prefix) and sling the
feature-dev formula to the selected semantic implementation target.

  --rig NAME     run in this rig (default: infer from the bead prefix)
  --base REF     branch point / merge target (default: origin/main)
  --offline      do not fetch the selected remote base; mark freshness unverified
  --quality      N=2 bounded review/revise lifecycle (default)
  --fast, --solo lower-cost N=1 lifecycle; still local-only and approval-gated
  --execution PROFILE  leaf-agent capacity: frontier-xhigh (default),
                       frontier-medium, efficient-xhigh, or efficient-medium
  --implementer-target T  explicit installed-target override for implementation
  --revision N   artifact revision number (default: 1)
  --previous-artifact ID  required with revision N>1
  --feedback-bead ID      review/synthesis bead producing revision N>1
  --verdict VERDICT       verdict producing revision N>1
  --review-n N            lifecycle review fan-out: 1 or 2 (default: 2)
  --max-review-iterations N  artifact revision cap (default: 3)
  --review-lanes A[,B]    reviewer profile targets; count must match --review-n
  --dry-run      print the gc sling command without running it
  -h, --help
EOF
}
die() { printf '%s\n' "feature: $*" >&2; exit 2; }
AGENTS_CACHE=""
load_agents() { [ -n "$AGENTS_CACHE" ] || AGENTS_CACHE="$("$GC" --city "$CITY" agent list 2>/dev/null | awk '{print $1}')"; }
agent_exists() { load_agents; printf '%s\n' "$AGENTS_CACHE" | grep -qx "$1"; }
RESOLVED_TARGET=""
resolve_target() { # $1=target, $2=optional short-name prefix
    local raw="$1" prefix="${2:-}" cand
    if [[ "$raw" == */* ]]; then
        [[ "$raw" == "$RIG/"* ]] || die "target '$raw' belongs to a different rig; expected '$RIG/...'"
        agent_exists "$raw" || die "unknown installed target '$raw'"
        RESOLVED_TARGET="$raw"
        return
    fi
    for cand in "$RIG/$raw" "$RIG/$prefix$raw"; do
        if agent_exists "$cand"; then RESOLVED_TARGET="$cand"; return; fi
    done
    die "unknown installed target '$raw' in rig '$RIG'"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)      RIG="${2:?}"; shift 2 ;;
        --rig=*)    RIG="${1#*=}"; shift ;;
        --base)     BASE="${2:?}"; shift 2 ;;
        --base=*)   BASE="${1#*=}"; shift ;;
        --offline)  FETCH_BASE="false"; shift ;;
        --quality)  PRESET="quality"; shift ;;
        --fast|--solo) PRESET="fast"; shift ;;
        --execution) EXECUTION="${2:?}"; shift 2 ;;
        --execution=*) EXECUTION="${1#*=}"; shift ;;
        --implementer-target) IMPLEMENTER_TARGET="${2:?}"; shift 2 ;;
        --implementer-target=*) IMPLEMENTER_TARGET="${1#*=}"; shift ;;
        --revision) REVISION="${2:?}"; shift 2 ;;
        --revision=*) REVISION="${1#*=}"; shift ;;
        --previous-artifact) PREVIOUS_ARTIFACT="${2:?}"; shift 2 ;;
        --previous-artifact=*) PREVIOUS_ARTIFACT="${1#*=}"; shift ;;
        --feedback-bead) FEEDBACK_BEAD="${2:?}"; shift 2 ;;
        --feedback-bead=*) FEEDBACK_BEAD="${1#*=}"; shift ;;
        --verdict) PRODUCING_VERDICT="${2:?}"; shift 2 ;;
        --verdict=*) PRODUCING_VERDICT="${1#*=}"; shift ;;
        --review-n) REVIEW_N_SET=true; REVIEW_N="${2:?}"; shift 2 ;;
        --review-n=*) REVIEW_N_SET=true; REVIEW_N="${1#*=}"; shift ;;
        --max-review-iterations) MAX_REVIEW_ITERATIONS="${2:?}"; shift 2 ;;
        --max-review-iterations=*) MAX_REVIEW_ITERATIONS="${1#*=}"; shift ;;
        --review-lanes) REVIEW_LANES_SET=true; IFS=',' read -r REVIEW_LANE_A REVIEW_LANE_B _ <<<"${2:?}"; shift 2 ;;
        --review-lanes=*) REVIEW_LANES_SET=true; IFS=',' read -r REVIEW_LANE_A REVIEW_LANE_B _ <<<"${1#*=}"; shift ;;
        --dry-run)  DRYRUN="yes"; shift ;;
        -h|--help)  usage; exit 0 ;;
        --)         shift; break ;;
        -*)         die "unknown option '$1'" ;;
        *)          if [ -z "$BEAD" ]; then BEAD="$1"; shift; else die "unexpected argument '$1'"; fi ;;
    esac
done
[ $# -eq 0 ] || { [ -z "$BEAD" ] && BEAD="$1"; }
[ -n "$BEAD" ] || { usage >&2; die "missing <bead>"; }
if [ "$REVIEW_N_SET" = false ]; then
    case "$PRESET" in
        quality) REVIEW_N=$(jq -er '.presets.quality.feature.review_n' "$POLICY") ;;
        fast) REVIEW_N=$(jq -er '.presets.fast.feature.review_n' "$POLICY") ;;
    esac
fi
case "$REVISION" in ''|*[!0-9]*) die "--revision must be a positive integer" ;; esac
[ "$REVISION" -ge 1 ] || die "--revision must be a positive integer"
case "$REVIEW_N" in 1|2) ;; *) die "--review-n must be 1 or 2" ;; esac
case "$MAX_REVIEW_ITERATIONS" in ''|*[!0-9]*) die "--max-review-iterations must be a positive integer" ;; esac
[ "$MAX_REVIEW_ITERATIONS" -ge 1 ] || die "--max-review-iterations must be a positive integer"
if [ "$REVISION" -eq 1 ]; then
    [ -z "$PREVIOUS_ARTIFACT$FEEDBACK_BEAD$PRODUCING_VERDICT" ] \
        || die "revision 1 cannot name prior review lineage"
else
    [ -n "$PREVIOUS_ARTIFACT" ] && [ -n "$FEEDBACK_BEAD" ] && [ -n "$PRODUCING_VERDICT" ] \
        || die "revision $REVISION requires --previous-artifact, --feedback-bead, and --verdict"
fi

# Resolve the rig: explicit --rig wins; else infer from the bead prefix (<rig>-<n>).
if [ -z "$RIG" ]; then
    RIG="${BEAD%-*}"
    [ -n "$RIG" ] && [ "$RIG" != "$BEAD" ] || die "cannot infer rig from bead '$BEAD'; pass --rig NAME"
fi
python3 "$VALIDATE_EXECUTION" --city "$CITY" --policy "$POLICY" --rig "$RIG" --profile "$EXECUTION" >/dev/null
[ -n "$IMPLEMENTER_TARGET" ] || IMPLEMENTER_TARGET="$RIG/$(jq -er --arg p "$EXECUTION" '.execution_profiles[$p].roles.feature.implementer' "$POLICY")"
[ -n "$REVIEW_LANE_A" ] || REVIEW_LANE_A="$RIG/$(jq -er --arg p "$EXECUTION" '.execution_profiles[$p].roles.review.lane_a' "$POLICY")"
if [ "$REVIEW_N" = "2" ]; then
    [ "$REVIEW_LANES_SET" = "false" ] || [ -n "$REVIEW_LANE_B" ] \
        || die "--review-n 2 requires two --review-lanes profiles"
    [ -n "$REVIEW_LANE_B" ] || REVIEW_LANE_B="$RIG/$(jq -er --arg p "$EXECUTION" '.execution_profiles[$p].roles.review.lane_b' "$POLICY")"
else
    [ -z "$REVIEW_LANE_B" ] || die "--review-n 1 accepts exactly one --review-lanes profile"
    REVIEW_LANE_B="$RIG/$(jq -er --arg p "$EXECUTION" '.execution_profiles[$p].roles.review.lane_b' "$POLICY")"
fi
resolve_target "$IMPLEMENTER_TARGET"; IMPLEMENTER_TARGET="$RESOLVED_TARGET"
resolve_target "$REVIEW_LANE_A" "pr-reviewer-"; REVIEW_LANE_A="$RESOLVED_TARGET"
resolve_target "$REVIEW_LANE_B" "pr-reviewer-"; REVIEW_LANE_B="$RESOLVED_TARGET"

set -- "$IMPLEMENTER_TARGET" feature-dev --formula \
    --var "work_bead=$BEAD" --var "base=$BASE" --var "fetch_base=$FETCH_BASE" \
    --var "revision=$REVISION" --var "previous_artifact_id=$PREVIOUS_ARTIFACT" \
    --var "feedback_bead=$FEEDBACK_BEAD" --var "producing_verdict=$PRODUCING_VERDICT" \
    --var "review_n=$REVIEW_N" --var "max_review_iterations=$MAX_REVIEW_ITERATIONS" \
    --var "implementer_target=$IMPLEMENTER_TARGET" \
    --var "review_lane_a_target=$REVIEW_LANE_A" --var "review_lane_b_target=$REVIEW_LANE_B" \
    --title "feature-dev: $BEAD" --json

if [ "$DRYRUN" = "yes" ]; then
    printf 'DRY RUN — would run (rig=%s, preset=%s, execution=%s, implementer_target=%s, review_lane_a_target=%s, review_lane_b_target=%s, review_n=%s, local_only=true, completion=approved):\n  %s --rig %s sling' \
        "$RIG" "$PRESET" "$EXECUTION" "$IMPLEMENTER_TARGET" "$REVIEW_LANE_A" "$REVIEW_LANE_B" "$REVIEW_N" "$GC" "$RIG"
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
    exit 0
fi

printf '%s\n' "feature: slinging feature-dev for '$BEAD' in rig '$RIG'" >&2
exec "$GC" --city "$CITY" --rig "$RIG" sling "$@"
