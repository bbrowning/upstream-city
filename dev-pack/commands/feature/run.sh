#!/usr/bin/env bash
# feature — kick off a single-lane feature implementation without hand-typing the sling.
#
#   gc dev-pack feature <bead> [options]
#
# Resolves the RIG (explicit --rig wins, else inferred from the bead prefix, e.g.
# vllm-123 -> vllm), then slings the feature-dev formula to <rig>/feature-dev, which
# implements and commits the assignment on a local paude/<bead> branch in its own
# worktree. The operator exports the commit; the arc closes on a real checkpoint.
#
# Env (provided by gc): GC_CITY_PATH, GC_BIN.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"

RIG="" ; BASE="origin/main" ; BEAD="" ; DRYRUN="no" ; FETCH_BASE="true"
REVISION="1" ; PREVIOUS_ARTIFACT="" ; FEEDBACK_BEAD="" ; PRODUCING_VERDICT=""
REVIEW_N="2" ; MAX_REVIEW_ITERATIONS="3"
REVIEW_LANE_A="" ; REVIEW_LANE_B=""
REVIEW_LANES_SET="false" ; REVIEW_N_SET="false" ; PRESET="quality"

usage() {
    cat <<'EOF'
usage: gc dev-pack feature <bead> [options]

Resolve the rig (--rig, else inferred from the bead prefix) and sling the
feature-dev formula to <rig>/feature-dev.

  --rig NAME     run in this rig (default: infer from the bead prefix)
  --base REF     branch point / merge target (default: origin/main)
  --offline      do not fetch the selected remote base; mark freshness unverified
  --quality      N=2 bounded review/revise lifecycle (default)
  --fast, --solo lower-cost N=1 lifecycle; still local-only and approval-gated
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

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)      RIG="${2:?}"; shift 2 ;;
        --rig=*)    RIG="${1#*=}"; shift ;;
        --base)     BASE="${2:?}"; shift 2 ;;
        --base=*)   BASE="${1#*=}"; shift ;;
        --offline)  FETCH_BASE="false"; shift ;;
        --quality)  PRESET="quality"; shift ;;
        --fast|--solo) PRESET="fast"; shift ;;
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
    case "$PRESET" in quality) REVIEW_N=2 ;; fast) REVIEW_N=1 ;; esac
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
[ -n "$REVIEW_LANE_A" ] || REVIEW_LANE_A="$RIG/pr-reviewer-sonnet-xhigh"
if [ "$REVIEW_N" = "2" ]; then
    [ "$REVIEW_LANES_SET" = "false" ] || [ -n "$REVIEW_LANE_B" ] \
        || die "--review-n 2 requires two --review-lanes profiles"
    [ -n "$REVIEW_LANE_B" ] || REVIEW_LANE_B="$RIG/pr-reviewer-gpt56luna-xhigh"
else
    [ -z "$REVIEW_LANE_B" ] || die "--review-n 1 accepts exactly one --review-lanes profile"
    REVIEW_LANE_B="$RIG/pr-reviewer-gpt56luna-xhigh"
fi

set -- "$RIG/feature-dev" feature-dev --formula \
    --var "work_bead=$BEAD" --var "base=$BASE" --var "fetch_base=$FETCH_BASE" \
    --var "revision=$REVISION" --var "previous_artifact_id=$PREVIOUS_ARTIFACT" \
    --var "feedback_bead=$FEEDBACK_BEAD" --var "producing_verdict=$PRODUCING_VERDICT" \
    --var "review_n=$REVIEW_N" --var "max_review_iterations=$MAX_REVIEW_ITERATIONS" \
    --var "review_lane_a_target=$REVIEW_LANE_A" --var "review_lane_b_target=$REVIEW_LANE_B" \
    --title "feature-dev: $BEAD" --json

if [ "$DRYRUN" = "yes" ]; then
    printf 'DRY RUN — would run (rig=%s, preset=%s, review_n=%s, local_only=true, completion=approved):\n  %s --rig %s sling' \
        "$RIG" "$PRESET" "$REVIEW_N" "$GC" "$RIG"
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
    exit 0
fi

printf '%s\n' "feature: slinging feature-dev for '$BEAD' in rig '$RIG'" >&2
exec "$GC" --city "$CITY" --rig "$RIG" sling "$@"
