#!/usr/bin/env bash
# review — kick off a posture-gated PR review without hand-typing the sling.
#
#   gc dev-pack review <PR-number | ref> [options]
#
# N = the opinion count (the fan-out dial). --n 1 (default) slings the pr-review formula
# (triage -> single posture-gated read-only review). --n 2 slings pr-review-quorum
# (triage -> two independent reviewer lanes -> a synthesis step that takes the strictest
# merge call). The verdict lands in the human inbox (`gc mail check`) and can be
# re-rendered later with `gc dev-pack summary <bead|PR>`.
#
# Env (provided by gc): GC_CITY_PATH, GC_BIN.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"

RIG="vllm" ; BASE="origin/main" ; SPEC="" ; DRYRUN="no"
N="1" ; MODELS=""

usage() {
    cat <<'EOF'
usage: gc dev-pack review <PR-number | ref> [options]

Sling the review formula (N=1 -> pr-review, N=2 -> pr-review-quorum) to <rig>/pr-reviewer.

  --rig NAME       rig the PR belongs to           (default: vllm)
  --base REF       baseline the diff is against     (default: origin/main)
  --n N            opinion count / fan-out: 1 (single reviewer, default) or 2 (quorum)
  --models M[,M]   per-run reviewer models, positional to the lanes (best-effort; N=2).
                   The RELIABLE quorum models are the per-lane agents' city.toml
                   option_defaults (pr-reviewer-a=opus, pr-reviewer-b=sonnet) — a
                   per-step opt_model does not reliably override them (follow-up).
  --dry-run        print the gc sling command without running it
  -h, --help
EOF
}
die() { printf '%s\n' "review: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)      RIG="${2:?}"; shift 2 ;;
        --rig=*)    RIG="${1#*=}"; shift ;;
        --base)     BASE="${2:?}"; shift 2 ;;
        --base=*)   BASE="${1#*=}"; shift ;;
        --n)        N="${2:?}"; shift 2 ;;
        --n=*)      N="${1#*=}"; shift ;;
        --models)   MODELS="${2:?}"; shift 2 ;;
        --models=*) MODELS="${1#*=}"; shift ;;
        --dry-run)  DRYRUN="yes"; shift ;;
        -h|--help)  usage; exit 0 ;;
        --)         shift; break ;;
        -*)         die "unknown option '$1'" ;;
        *)          if [ -z "$SPEC" ]; then SPEC="$1"; shift; else die "unexpected argument '$1'"; fi ;;
    esac
done
[ $# -eq 0 ] || { [ -z "$SPEC" ] && SPEC="$1"; }
[ -n "$SPEC" ] || { usage >&2; die "missing <PR-number | ref>"; }

# Only two reviewer lane-steps exist today, so N is 1 or 2.
case "$N" in
    1|2) ;;
    *) die "--n must be 1 or 2 (got '$N')" ;;
esac

if [ "$N" = "1" ]; then
    [ -z "$MODELS" ] || printf '%s\n' "review: WARN N=1 ignores --models (single reviewer uses its option_defaults)" >&2
    set -- "$RIG/pr-reviewer" pr-review --formula \
        --var "head_ref=$SPEC" --var "base_ref=$BASE" \
        --title "pr-review: $SPEC" --json
else
    # Split --models positionally onto the two lanes; empty defers to option_defaults.
    LANE_A_MODEL="" ; LANE_B_MODEL=""
    if [ -n "$MODELS" ]; then
        IFS=',' read -r LANE_A_MODEL LANE_B_MODEL _ <<<"$MODELS" || true
    fi
    set -- "$RIG/pr-reviewer" pr-review-quorum --formula \
        --var "head_ref=$SPEC" --var "base_ref=$BASE" \
        --var "triage_target=$RIG/pr-triage" \
        --var "lane_a_target=$RIG/pr-reviewer-a" \
        --var "lane_b_target=$RIG/pr-reviewer-b" \
        --var "synthesis_target=$RIG/pr-reviewer"
    if [ -n "${LANE_A_MODEL:-}" ]; then set -- "$@" --var "lane_a_model=$LANE_A_MODEL"; fi
    if [ -n "${LANE_B_MODEL:-}" ]; then set -- "$@" --var "lane_b_model=$LANE_B_MODEL"; fi
    set -- "$@" --title "pr-review-quorum: $SPEC" --json
fi

if [ "$DRYRUN" = "yes" ]; then
    printf 'DRY RUN — would run (rig=%s, n=%s):\n  %s --rig %s sling' "$RIG" "$N" "$GC" "$RIG"
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
    exit 0
fi

printf '%s\n' "review: slinging review (N=$N) for '$SPEC' in rig '$RIG'" >&2
exec "$GC" --city "$CITY" --rig "$RIG" sling "$@"
