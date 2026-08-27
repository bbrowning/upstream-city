#!/usr/bin/env bash
# settle — resolve a DIVERGED PR-review quorum by evidence (the settle round).
#
#   gc dev-pack settle <PR-number | rig#PR | bead-id> [options]
#
#   gc dev-pack settle 51937                       # settle the newest quorum verdict for PR 51937
#   gc dev-pack settle 51937 --arbiter b-frontier-xhigh   # use the semantic B reviewer
#
# WHY THIS EXISTS: when a review quorum's lanes DIVERGE on a load-bearing finding,
# `pr-review-quorum` takes the strictest call, NAMES the crux, and stops — handing the
# dispute to a human. This is the Phase-1 MANUAL entry point that settles it: it resolves
# the quorum's synthesis verdict + both lane verdicts and slings `pr-review-settle`, whose
# verify-mandated ARBITER (a 3rd, ideally independent, model) RESOLVES the crux by
# `file:line` static reads (escalating to a scoped `needs_dynamic` check when static can't
# fully close), emits a `pr-review-settle.v1` report, and re-synthesizes the final verdict.
# Settle by VERIFYING the keystone, never a tiebreaker vote (base.md #7 applied to the
# reviewers' claims).
#
# The report lands in the human inbox (`gc mail check`) and is re-renderable with
# `gc dev-pack summary <settle-bead>`. (Auto-on-divergence is Phase 2 — the
# `enable_settle` dial on `pr-review-quorum`; today it is report-only + this command.)
#
# Args:
#   <PR-number | rig#PR | bead-id>  a PR number N (resolved to its newest quorum verdict bead),
#                           or a quorum/review verdict bead id used directly.
#
# Options:
#   --rig <name>       rig the PR belongs to                    (default: vllm)
#   --base <ref>       baseline the diff is against; falls back to the verdict's own
#                      base_ref, then origin/main               (default: origin/main)
#   --arbiter <name>   installed semantic/custom reviewer target to arbitrate (resolves to:
#                      '<name>', 'pr-reviewer-<name>', or the default 'pr-arbiter').
#                      Use an independent semantic lane when a separate view is useful.
#   --dry-run          validate + print the gc sling command without running it
#   -h, --help
#
# Env (provided by gc): GC_CITY_PATH, GC_BIN.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$SCRIPT_DIR/../../assets/scripts/resolve-verdict-bead.sh"
NORMALIZE="$SCRIPT_DIR/../../assets/scripts/normalize-pr-target.sh"

RIG="vllm" ; BASE="" ; SPEC="" ; ARBITER="" ; DRYRUN="no"
RIG_EXPLICIT=0

usage() { sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf '%s\n' "settle: $*" >&2; exit 2; }

# --- agent lookup (cached) ---------------------------------------------------
AGENTS_CACHE=""
load_agents() { [ -n "$AGENTS_CACHE" ] || AGENTS_CACHE="$("$GC" --city "$CITY" agent list 2>/dev/null | awk '{print $1}')"; }
agent_exists() { load_agents; printf '%s\n' "$AGENTS_CACHE" | grep -qx "$1"; }
available_arbiters() { load_agents; printf '%s\n' "$AGENTS_CACHE" | grep -E "^$RIG/(pr-arbiter|pr-reviewer-)" | sed "s#^$RIG/##" | paste -sd',' - | sed 's/,/, /g'; }
RESOLVED=""
resolve_arbiter() {  # $1=name -> sets RESOLVED to a rig-qualified agent, or dies
    local e="$1" cand
    for cand in "$RIG/$e" "$RIG/pr-reviewer-$e" "$RIG/pr-arbiter-$e"; do
        if agent_exists "$cand"; then RESOLVED="$cand"; return 0; fi
    done
    die "unknown arbiter target '$e'. Available: $(available_arbiters). (Default: pr-arbiter.)"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)       RIG="${2:?}"; RIG_EXPLICIT=1; shift 2 ;;
        --rig=*)     RIG="${1#*=}"; RIG_EXPLICIT=1; shift ;;
        --base)      BASE="${2:?}"; shift 2 ;;
        --base=*)    BASE="${1#*=}"; shift ;;
        --arbiter)   ARBITER="${2:?}"; shift 2 ;;
        --arbiter=*) ARBITER="${1#*=}"; shift ;;
        --dry-run)   DRYRUN="yes"; shift ;;
        -h|--help)   usage; exit 0 ;;
        --)          shift; break ;;
        -*)          die "unknown option '$1'" ;;
        *)           if [ -z "$SPEC" ]; then SPEC="$1"; shift; else die "unexpected argument '$1'"; fi ;;
    esac
done
[ $# -eq 0 ] || { [ -z "$SPEC" ] && SPEC="$1"; }
[ -n "$SPEC" ] || { usage >&2; die "missing <PR-number | rig#PR | bead-id>"; }
[ -x "$RESOLVE" ] || die "resolver not found/executable: $RESOLVE"
[ -x "$NORMALIZE" ] || die "target normalizer not found/executable: $NORMALIZE"
NORM_ARGS=(--rig "$RIG")
[ "$RIG_EXPLICIT" -eq 1 ] && NORM_ARGS+=(--rig-explicit)
NORM=$("$NORMALIZE" "$SPEC" "${NORM_ARGS[@]}") || exit $?
SPEC=$(printf '%s' "$NORM" | jq -r '.spec')
RIG=$(printf '%s' "$NORM" | jq -r '.rig')

# --- 1. Resolve the quorum SYNTHESIS verdict bead ----------------------------
SYNTH=$("$RESOLVE" "$SPEC" --rig "$RIG") || exit $?

read_meta() { printf '%s' "$1" | jq -r --arg k "$2" '.[0].metadata[$k] // empty'; }

SHOW=$("$GC" --city "$CITY" --rig "$RIG" bd show "$SYNTH" --json 2>/dev/null) \
    || die "could not read bead '$SYNTH' in rig '$RIG' (city '$CITY') — wrong --rig?"
[ "$(printf '%s' "$SHOW" | jq -r 'length')" -gt 0 ] 2>/dev/null \
    || die "bead '$SYNTH' not found in rig '$RIG' (try --rig <name>)"

# If we resolved to a POST-SETTLE re-synthesis verdict, hop back to the ORIGINAL quorum
# synthesis it settled (it carries the lane deps the arbiter needs; a re-synthesis does not).
ROLE=$(read_meta "$SHOW" "gc.review_settle_role")
if [ "$ROLE" = "resynthesis" ]; then
    ORIG=$(read_meta "$SHOW" "gc.settle_of")
    [ -n "$ORIG" ] || die "bead '$SYNTH' is a re-synthesis but carries no gc.settle_of pointer"
    printf 'settle: %s is a post-settle re-synthesis -> original synthesis %s\n' "$SYNTH" "$ORIG" >&2
    SYNTH="$ORIG"
    SHOW=$("$GC" --city "$CITY" --rig "$RIG" bd show "$SYNTH" --json 2>/dev/null) \
        || die "could not read original synthesis bead '$SYNTH'"
fi

VJSON=$(read_meta "$SHOW" "gc.output_json")
[ -n "$VJSON" ] || die "bead '$SYNTH' has no gc.output_json verdict (not a finished quorum synthesis?)"

SCHEMA=$(read_meta "$SHOW" "gc.output_json_schema")
if [ "$SCHEMA" != "pr-review-quorum.v1" ]; then
    die "bead '$SYNTH' is schema '$SCHEMA', not pr-review-quorum.v1 — a settle round needs a QUORUM (N>=2) verdict with lane divergence.
Run a quorum first: gc dev-pack review $SPEC --n 2   (or pass the quorum synthesis bead id)."
fi

HEAD_REF=$(printf '%s' "$VJSON" | jq -r '.head_ref // empty')
[ -n "$HEAD_REF" ] || die "verdict on '$SYNTH' has no head_ref — cannot settle"
HEAD_NORM=$("$NORMALIZE" "$HEAD_REF" --rig "$RIG" --rig-explicit) || exit $?
HEAD_REF=$(printf '%s' "$HEAD_NORM" | jq -r '.spec')
# base_ref precedence: explicit --base > the verdict's own base_ref > origin/main.
if [ -z "$BASE" ]; then BASE=$(printf '%s' "$VJSON" | jq -r '.base_ref // "origin/main"'); fi
CRUX=$(printf '%s' "$VJSON" | jq -r '.crux_question // empty')

# --- 2. Find the reviewer LANE beads off the synthesis bead's deps ------------
# Lane beads are the deps stamped gc.review_quorum_lane (in lane-id order: reviewer-a…).
mapfile -t LANE_BEADS < <(printf '%s' "$SHOW" | jq -r '
    [ .[0].dependencies[]?
      | select(.metadata["gc.review_quorum_lane"] != null)
      | {id, lane: .metadata["gc.review_quorum_lane"]} ]
    | sort_by(.lane) | .[].id')
LN=${#LANE_BEADS[@]}
if [ "$LN" -lt 2 ]; then
    die "synthesis bead '$SYNTH' has $LN reviewer-lane dep(s) — need >=2 to settle a divergence.
(Is this actually a quorum synthesis? A solo N=1 review has nothing to settle.)"
fi
[ "$LN" -eq 2 ] || printf 'settle: %s lanes found; Phase 1 settles the first two (%s, %s)\n' \
    "$LN" "${LANE_BEADS[0]}" "${LANE_BEADS[1]}" >&2
LANE_A="${LANE_BEADS[0]}" ; LANE_B="${LANE_BEADS[1]}"

# --- 3. Divergence advisory (do not hard-gate a manual run) -------------------
DIVERGED=$(printf '%s' "$VJSON" | jq -r '
    ((.has_disputed_major // false) or
     ((.lanes // []) | map(.verdict) | unique | length) > 1)')
if [ "$DIVERGED" != "true" ]; then
    printf 'settle: WARNING — verdict %s does not look diverged (lanes agree, no disputed>=major).\n' "$SYNTH" >&2
    printf '        The arbiter will report "no load-bearing dispute" if it finds none.\n' >&2
fi

# --- 4. Resolve the arbiter target -------------------------------------------
if [ -n "$ARBITER" ]; then resolve_arbiter "$ARBITER"; ATARGET="$RESOLVED"
else
    ATARGET="$RIG/pr-arbiter"
    agent_exists "$ATARGET" || die "default arbiter '$ATARGET' not found — run 'gc reload'? Or pass --arbiter <target> (available: $(available_arbiters))."
fi

# --- 5. Build + run the sling -------------------------------------------------
set -- "$ATARGET" pr-review-settle --formula \
    --var "head_ref=$HEAD_REF" --var "base_ref=$BASE" \
    --var "synth_bead=$SYNTH" \
    --var "lane_a_bead=$LANE_A" --var "lane_b_bead=$LANE_B" \
    --var "crux_question=$CRUX" \
    --var "arbiter_target=$ATARGET" \
    --var "resynth_target=$RIG/pr-review-synthesizer" \
    --title "pr-review-settle: $HEAD_REF" --json

if [ "$DRYRUN" = "yes" ]; then
    printf 'DRY RUN — settle PR %s (synthesis %s, lanes %s/%s, arbiter %s):\n  %s --city %q --rig %s sling' \
        "$HEAD_REF" "$SYNTH" "$LANE_A" "$LANE_B" "$ATARGET" "$GC" "$CITY" "$RIG"
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
    exit 0
fi

printf 'settle: slinging settle round for PR %s (synthesis %s; arbiter %s)\n' "$HEAD_REF" "$SYNTH" "$ATARGET" >&2
exec "$GC" --city "$CITY" --rig "$RIG" sling "$@"
