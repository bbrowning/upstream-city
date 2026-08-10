#!/usr/bin/env bash
# summary — re-render a stored PR-review (pr-review.v1) or dynamic-check
# (pr-review-dynamic.v1) verdict as a human-readable summary, on demand.
#
#   gc dev-pack summary <bead-id | PR-number> [options]
#
# WHY THIS EXISTS: the verdict mail is ephemeral (retention-swept), and reading
# the bead directly gives you raw JSON. This is the durable, LLM-free companion
# to `materialize`: point it at the review bead id printed in the verdict mail
# (the `gc bd show <bead> --json` pointer), or at a PR number, and it prints the
# SAME summary emit-verdict.sh mails at finish time — via the very same renderer,
# so mail and on-demand output never drift. Full fidelity always stays on the
# bead; this only reads it.
#
# Args:
#   <bead-id | PR-number>   a review/dynamic step bead id (e.g. vllm-957), or a
#                           bare PR number N (resolved to the newest pr-review.v1
#                           bead whose head_ref matches PR N).
#
# Options:
#   --rig <name>   rig context for PR resolution + the approval hint (default: vllm)
#   -h, --help     show this help
#
# Env (provided by gc): GC_CITY_PATH, GC_BIN. Optional: GC_DASHBOARD_BASE.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER="$SCRIPT_DIR/../../assets/scripts/render-verdict.sh"

RIG="vllm"
SPEC=""

usage() {
    printf '%s\n' \
        "usage: gc dev-pack summary <bead-id | PR-number> [--rig N]" \
        "" \
        "Re-render a stored verdict (pr-review.v1 / pr-review-dynamic.v1) as the same" \
        "human-readable summary the verdict mail carries. Pass the bead id from the" \
        "mail (gc bd show <bead> --json), or a bare PR number to look it up."
}
die() { printf '%s\n' "summary: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)     RIG="${2:?--rig needs a value}"; shift 2 ;;
        --rig=*)   RIG="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        --)        shift; break ;;
        -*)        die "unknown option '$1'" ;;
        *)         if [ -z "$SPEC" ]; then SPEC="$1"; shift; else die "unexpected argument '$1'"; fi ;;
    esac
done
[ $# -eq 0 ] || { [ -z "$SPEC" ] && SPEC="$1"; }
[ -n "$SPEC" ] || { usage >&2; die "missing <bead-id | PR-number>"; }
[ -x "$RENDER" ] || die "renderer not found/executable: $RENDER"

# Resolve the target bead. A bead id carries a non-digit (e.g. vllm-957); a bare
# integer is a PR number to look up among closed pr-review verdict beads.
if printf '%s' "$SPEC" | grep -qE '^[0-9]+$'; then
    N="$SPEC"
    BEAD=$("$GC" --city "$CITY" --rig "$RIG" bd list --all --json \
             --metadata-field "gc.output_json_schema=pr-review.v1" -n 0 2>/dev/null \
           | jq -r --arg n "$N" '
               [ .[]?
                 | . as $b
                 | ($b.metadata["gc.output_json"] // "" | fromjson?) as $vj
                 | select($vj != null
                          and (($vj.head_ref // "") | tostring
                               | test("(^|[^0-9])" + $n + "([^0-9]|$)")))
                 | {id: $b.id,
                    ts: ($b.closed_at // $b.updated_at // $b.created_at // ""),
                    canon: (($b.close_reason // "") | test("^(review|dynamic check):"))}
               ] as $all
               # Prefer the bead emit-verdict.sh actually closed+mailed (its close
               # reason marks it); a run can also leave framework copy/finalize beads
               # carrying the same schema. Fall back to all if none are marked.
               | (($all | map(select(.canon))) as $c
                  | if ($c|length) > 0 then $c else $all end)
               | sort_by(.ts) | last | .id // empty' 2>/dev/null || true)
    [ -n "$BEAD" ] || die "no pr-review verdict bead found for PR $N in rig '$RIG'.
Try --rig <name>, or pass the bead id from the verdict mail: gc dev-pack summary <bead-id>"
    printf '%s\n' "summary: PR $N -> review bead $BEAD" >&2
else
    BEAD="$SPEC"
fi

# Read the stored verdict JSON + root bead id from metadata (the same
# gc.output_json emit-verdict.sh wrote at finish time).
SHOW=$("$GC" --city "$CITY" --rig "$RIG" bd show "$BEAD" --json 2>/dev/null) \
    || die "could not read bead '$BEAD' in rig '$RIG' (city '$CITY') — wrong --rig?"
[ "$(printf '%s' "$SHOW" | jq -r 'length')" -gt 0 ] 2>/dev/null \
    || die "bead '$BEAD' not found in rig '$RIG' (try --rig <name>)"
VJSON=$(printf '%s' "$SHOW" | jq -r '.[0].metadata["gc.output_json"] // empty')
[ -n "$VJSON" ] \
    || die "bead '$BEAD' has no gc.output_json verdict (not a finished review / dynamic-check step?)"

root=$(printf '%s' "$SHOW" | jq -r '.[0].metadata["gc.root_bead_id"] // empty')
base="${GC_DASHBOARD_BASE:-http://127.0.0.1:8372/city/workspace/runs}"
RUN_URL=""
[ -n "$root" ] && RUN_URL="${base}/${root}"

printf '%s' "$VJSON" | "$RENDER" - --bead "$BEAD" --run-url "$RUN_URL" --rig "$RIG"
