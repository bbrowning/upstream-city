#!/usr/bin/env bash
# bug — launch a bug run without hand-typing agent targets.
#
#   gc dev-pack bug <arc-bead> [options]
#
# N = the opinion count (the fan-out dial). Quality defaults to --n 2 with the full
# convergence loop. --fast/--solo runs one lane; --report-only pauses after diagnosis.
# hard-bug-round-solo provides solo diagnosis + keystone self-verify; --n 2 runs two lanes
# that act as each other's second opinion (hard-bug-round + the correlated-convergence
# gate). Resolves the RIG (explicit --rig wins, else inferred from the bead prefix, e.g.
# vllm-123 -> vllm), then slings the round formula to <rig>/bug-coordinator with the
# <rig>/bug-worker-* lane targets filled in — so it can't rig-mismatch and you never
# type targets. The bead must live in that rig, and the pack must be attached to it
# (includes = ["dev-pack"] + `gc reload`).
#
# Env (provided by gc): GC_CITY_PATH, GC_BIN.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="$SCRIPT_DIR/../../assets/workflow-policy.json"
VALIDATE_EXECUTION="$SCRIPT_DIR/../../assets/scripts/validate-execution-profile.py"
[ -r "$POLICY" ] || { printf '%s\n' "bug: workflow policy not found: $POLICY" >&2; exit 2; }

BEAD="" ; RIG="" ; LOOP="" ; MAXR="$(jq -er '.defaults.max_rounds' "$POLICY")"
BASEREF="$(jq -er '.defaults.base_ref' "$POLICY")"
N="" ; PRESET="quality"
LANE_A_TARGET="" ; LANE_B_TARGET=""
BRANCH_PREFIX=""
REVIEW_N="$(jq -er '.presets.quality.bug.review_n' "$POLICY")" ; REVIEW_N_SET=false ; REVIEW_LANES=""
MAX_REVIEW_ITERATIONS="$(jq -er '.defaults.max_review_iterations' "$POLICY")"
DRYRUN="no"
EXECUTION="$(jq -er '.defaults.execution_profile' "$POLICY")"

usage() {
    cat <<'EOF'
usage: gc dev-pack bug <arc-bead> [options]

Resolve the rig (--rig, else inferred from the bead prefix) and sling the round
formula (N=1 -> hard-bug-round-solo, N=2 -> hard-bug-round) to <rig>/bug-coordinator
with the <rig>/bug-worker-* lane targets filled in.

  --rig NAME          run in this rig (default: infer from the bead prefix)
  --quality           N=2 full diagnosis, convergence, implementation, and review (default)
  --fast, --solo      lower-cost N=1 full bounded workflow
  --report-only       N=2 diagnosis report; do not converge or implement
  --n N               custom diagnosis opinion count / fan-out: 1 or 2
  --execution PROFILE leaf-agent capacity: frontier-xhigh (default),
                      frontier-medium, efficient-xhigh, or efficient-medium
  --loop              explicitly drive the full convergence loop (already on for quality/fast)
  --max-rounds N      per-phase iteration cap (default 3)
  --base-ref REF      baseline ref the lanes read against (default origin/main)
  --lane-a-target T   expert override for resolved lane A target
  --lane-b-target T   expert override for resolved lane B target (N=2 only)
  --branch-prefix P   prefix the eventual fix branch (default: unset -> no prefix)
  --review-n N        shared lifecycle review fan-out: 1 or 2 (default: 2)
  --review-lanes A[,B] reviewer profile targets; count must match --review-n
  --max-review-iterations N  artifact revision cap (default: 3)
  --dry-run           print the gc sling command without running it (skips live checks)
  -h, --help
EOF
}
die() { printf '%s\n' "bug: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)             RIG="${2:?}"; shift 2 ;;
        --rig=*)           RIG="${1#*=}"; shift ;;
        --quality)         PRESET="quality"; shift ;;
        --fast|--solo)     PRESET="fast"; shift ;;
        --report-only)     PRESET="report_only"; shift ;;
        --n)               N="${2:?}"; shift 2 ;;
        --n=*)             N="${1#*=}"; shift ;;
        --execution)       EXECUTION="${2:?}"; shift 2 ;;
        --execution=*)     EXECUTION="${1#*=}"; shift ;;
        --models|--lane-a-model|--lane-b-model) die "$1 is not a reliable launch override; use --execution or an explicit --lane-*-target" ;;
        --models=*|--lane-a-model=*|--lane-b-model=*) die "${1%%=*} is not a reliable launch override; use --execution or an explicit --lane-*-target" ;;
        --loop)            LOOP="true"; shift ;;
        --max-rounds)      MAXR="${2:?}"; shift 2 ;;
        --max-rounds=*)    MAXR="${1#*=}"; shift ;;
        --base-ref)        BASEREF="${2:?}"; shift 2 ;;
        --base-ref=*)      BASEREF="${1#*=}"; shift ;;
        --lane-a-target)   LANE_A_TARGET="${2:?}"; shift 2 ;;
        --lane-a-target=*) LANE_A_TARGET="${1#*=}"; shift ;;
        --lane-b-target)   LANE_B_TARGET="${2:?}"; shift 2 ;;
        --lane-b-target=*) LANE_B_TARGET="${1#*=}"; shift ;;
        --branch-prefix)   BRANCH_PREFIX="${2:?}"; shift 2 ;;
        --branch-prefix=*) BRANCH_PREFIX="${1#*=}"; shift ;;
        --review-n)        REVIEW_N_SET=true; REVIEW_N="${2:?}"; shift 2 ;;
        --review-n=*)      REVIEW_N_SET=true; REVIEW_N="${1#*=}"; shift ;;
        --review-lanes)    REVIEW_LANES="${2:?}"; shift 2 ;;
        --review-lanes=*)  REVIEW_LANES="${1#*=}"; shift ;;
        --max-review-iterations) MAX_REVIEW_ITERATIONS="${2:?}"; shift 2 ;;
        --max-review-iterations=*) MAX_REVIEW_ITERATIONS="${1#*=}"; shift ;;
        --dry-run)         DRYRUN="yes"; shift ;;
        -h|--help)         usage; exit 0 ;;
        --)                shift; break ;;
        -*)                die "unknown option '$1'" ;;
        *)                 if [ -z "$BEAD" ]; then BEAD="$1"; shift; else die "unexpected argument '$1'"; fi ;;
    esac
done
[ $# -eq 0 ] || { [ -z "$BEAD" ] && BEAD="$1"; }
[ -n "$BEAD" ] || { usage >&2; die "missing <arc-bead>"; }

case "$PRESET" in
    quality)     [ -n "$N" ] || N=$(jq -er '.presets.quality.bug.diagnosis_n' "$POLICY");
                 [ -n "$LOOP" ] || LOOP=$(jq -r '.presets.quality.bug.enable_loop' "$POLICY") ;;
    fast)        [ -n "$N" ] || N=$(jq -er '.presets.fast.bug.diagnosis_n' "$POLICY");
                 [ -n "$LOOP" ] || LOOP=$(jq -r '.presets.fast.bug.enable_loop' "$POLICY") ;;
    report_only) [ -n "$N" ] || N=$(jq -er '.presets.report_only.bug.diagnosis_n' "$POLICY");
                 [ -n "$LOOP" ] || LOOP=$(jq -r '.presets.report_only.bug.enable_loop' "$POLICY") ;;
esac
if [ "$REVIEW_N_SET" = false ]; then
    REVIEW_N=$(jq -er ".presets.${PRESET}.bug.review_n" "$POLICY")
fi

# Only two lane-steps exist today, so N is 1 or 2 (the structure extends to N>2 by
# adding lane-count formula variants).
case "$N" in
    1|2) ;;
    *) die "--n must be 1 or 2 (got '$N')" ;;
esac
case "$REVIEW_N" in 1|2) ;; *) die "--review-n must be 1 or 2" ;; esac
case "$MAX_REVIEW_ITERATIONS" in ''|*[!0-9]*) die "--max-review-iterations must be a positive integer" ;; esac
[ "$MAX_REVIEW_ITERATIONS" -ge 1 ] || die "--max-review-iterations must be a positive integer"

# Resolve the rig: explicit --rig wins; else infer from the bead prefix (<rig>-<n>).
if [ -z "$RIG" ]; then
    RIG="${BEAD%-*}"
    [ -n "$RIG" ] && [ "$RIG" != "$BEAD" ] || die "cannot infer rig from bead '$BEAD'; pass --rig NAME"
fi

COORD="$RIG/bug-coordinator"
python3 "$VALIDATE_EXECUTION" --city "$CITY" --policy "$POLICY" --rig "$RIG" --profile "$EXECUTION" >/dev/null
[ -n "$LANE_A_TARGET" ] || LANE_A_TARGET="$RIG/$(jq -er --arg p "$EXECUTION" '.execution_profiles[$p].roles.bug.lane_a' "$POLICY")"
[ -n "$LANE_B_TARGET" ] || LANE_B_TARGET="$RIG/$(jq -er --arg p "$EXECUTION" '.execution_profiles[$p].roles.bug.lane_b' "$POLICY")"
REVIEW_LANE_A="$RIG/$(jq -er --arg p "$EXECUTION" '.execution_profiles[$p].roles.review.lane_a' "$POLICY")"
REVIEW_LANE_B="$RIG/$(jq -er --arg p "$EXECUTION" '.execution_profiles[$p].roles.review.lane_b' "$POLICY")"
if [ -n "$REVIEW_LANES" ]; then
    IFS=',' read -r REVIEW_LANE_A REVIEW_LANE_B _ <<<"$REVIEW_LANES" || true
    [ -n "$REVIEW_LANE_A" ] || die "--review-lanes requires a lane A profile"
    if [ "$REVIEW_N" = "2" ]; then [ -n "$REVIEW_LANE_B" ] || die "--review-n 2 requires two --review-lanes profiles"
    else
        [ -z "$REVIEW_LANE_B" ] || die "--review-n 1 accepts one --review-lanes profile"
        REVIEW_LANE_B="$RIG/$(jq -er --arg p "$EXECUTION" '.execution_profiles[$p].roles.review.lane_b' "$POLICY")"
    fi
fi

# Pick the formula by opinion count.
if [ "$N" = "1" ]; then
    FORMULA="hard-bug-round-solo"
    if [ "$LANE_B_TARGET" != "$RIG/$(jq -er --arg p "$EXECUTION" '.execution_profiles[$p].roles.bug.lane_b' "$POLICY")" ]; then
        printf '%s\n' "bug: WARN N=1 ignores lane-B options (no second lane)" >&2
    fi
else
    FORMULA="hard-bug-round"
fi

# Live sanity checks (skipped under --dry-run so it stays a pure preview).
if [ "$DRYRUN" != "yes" ]; then
    "$GC" --city "$CITY" --rig "$RIG" bd show "$BEAD" --json >/dev/null 2>&1 \
        || die "bead '$BEAD' not found in rig '$RIG' (wrong --rig, or create it there first)"
    if ! "$GC" --city "$CITY" agent list 2>/dev/null | grep -q "$COORD"; then
        printf '%s\n' "bug: WARN '$COORD' not found — is dev-pack in rig '$RIG' includes, and has 'gc reload' run?" >&2
    fi
fi

set -- "$COORD" "$FORMULA" --formula \
    --var "bug_bead=$BEAD" --var "phase=root_cause" --var "round=1" \
    --var "max_rounds=$MAXR" --var "enable_loop=$LOOP" --var "base_ref=$BASEREF" \
    --var "review_n=$REVIEW_N" --var "max_review_iterations=$MAX_REVIEW_ITERATIONS" \
    --var "review_lane_a_target=$REVIEW_LANE_A" --var "review_lane_b_target=$REVIEW_LANE_B" \
    --var "lane_a_target=$LANE_A_TARGET" \
    --var "coordinator_target=$COORD"
# Lane B exists only at N=2.
if [ "$N" = "2" ]; then set -- "$@" --var "lane_b_target=$LANE_B_TARGET"; fi
# branch_prefix defaults to "" in the formula too, but only pass it explicitly
# when set so a --dry-run without it matches the formula's own default output.
if [ -n "$BRANCH_PREFIX" ]; then set -- "$@" --var "branch_prefix=$BRANCH_PREFIX"; fi
set -- "$@" --title "bug root-cause round 1: $BEAD" --json

if [ "$DRYRUN" = "yes" ]; then
    printf 'DRY RUN — would run (rig=%s, preset=%s, execution=%s, diagnosis_lane_a_target=%s, diagnosis_lane_b_target=%s, review_lane_a_target=%s, review_lane_b_target=%s, diagnosis_n=%s, loop=%s, review_n=%s, local_only=true, completion=approved):\n  %s --rig %s sling' \
        "$RIG" "$PRESET" "$EXECUTION" "$LANE_A_TARGET" "$LANE_B_TARGET" "$REVIEW_LANE_A" "$REVIEW_LANE_B" "$N" "$LOOP" "$REVIEW_N" "$GC" "$RIG"
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
    exit 0
fi

printf '%s\n' "bug: launching bug (N=$N) on $BEAD in rig '$RIG' (loop=$LOOP, max_rounds=$MAXR)" >&2
exec "$GC" --city "$CITY" --rig "$RIG" sling "$@"
