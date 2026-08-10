#!/usr/bin/env bash
# status — render a hard-bug arc's durable state (hard-bug-state.v1) as a compact,
# LLM-free summary. Point it at the arc/tracking bead you slung the workflow with.
#
#   gc dev-pack status <arc-bead> [--rig NAME]
#
# The state is written (and MERGE-updated) on the arc bead by the coordinator's
# reconcile/finalize steps, so this reflects live progress with no agent involved.
# Full fidelity always stays on the bead; this only reads it.
#
# Env (provided by gc): GC_CITY_PATH, GC_BIN, GC_RIG.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
RIG="${GC_RIG:-}"
BEAD=""

usage() { printf '%s\n' "usage: gc dev-pack status <arc-bead> [--rig NAME]"; }
die() { printf '%s\n' "status: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)     RIG="${2:?--rig needs a value}"; shift 2 ;;
        --rig=*)   RIG="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        --)        shift; break ;;
        -*)        die "unknown option '$1'" ;;
        *)         if [ -z "$BEAD" ]; then BEAD="$1"; shift; else die "unexpected argument '$1'"; fi ;;
    esac
done
[ $# -eq 0 ] || { [ -z "$BEAD" ] && BEAD="$1"; }
[ -n "$BEAD" ] || { usage >&2; die "missing <arc-bead>"; }

# Infer the rig from the bead prefix (e.g. vllm-123 -> vllm) when --rig / $GC_RIG is
# absent, the same way `bug` does — so `gc dev-pack status <bead>` just works.
if [ -z "$RIG" ]; then
    inferred="${BEAD%-*}"
    [ -n "$inferred" ] && [ "$inferred" != "$BEAD" ] && RIG="$inferred"
fi

RIGARG=()
[ -n "$RIG" ] && RIGARG=(--rig "$RIG")

SHOW=$("$GC" --city "$CITY" "${RIGARG[@]}" bd show "$BEAD" --json 2>/dev/null) \
    || die "could not read bead '$BEAD' (city '$CITY') — wrong --rig?"
[ "$(printf '%s' "$SHOW" | jq -r 'length')" -gt 0 ] 2>/dev/null \
    || die "bead '$BEAD' not found (try --rig <name>)"

STATE=$(printf '%s' "$SHOW" | jq -r '.[0].metadata["gc.output_json"] // empty')
[ -n "$STATE" ] \
    || die "bead '$BEAD' has no hard-bug-state.v1 yet (no reconcile step has run)"

printf '%s' "$STATE" | jq -r '
    "hard-bug arc: \(.bug_bead // "?")",
    "  phase:             \(.phase // "?")",
    "  rounds:            root_cause=\(.rounds.root_cause // 0)  fix=\(.rounds.fix // 0)   (cap \(.max_rounds // "?"))",
    "  status:            \(.status // "?")",
    "  chosen implementer:\(.chosen_implementer // "-")",
    "  last reconcile:    round \(.last_reconcile.round // "?")  aligned=\(if .last_reconcile.aligned == null then "?" else .last_reconcile.aligned end)",
    (if .agreed_root_cause then "  agreed root cause: \(.agreed_root_cause)" else empty end),
    (if .convoy_id then "  convoy:            \(.convoy_id)" else empty end)
'
