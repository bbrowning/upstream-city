#!/usr/bin/env bash
# resolve-verdict-bead.sh — resolve a PR number, review-verdict bead id, or
# follow-up bead id down to the ROOT review-verdict bead (pr-review.v1 /
# pr-review-quorum.v1). Prints just the bead id to stdout; diagnostics to stderr.
#
#   resolve-verdict-bead.sh <bead-id | PR-number> --rig <name>
#
# WHY THIS EXISTS: both `gc dev-pack summary` and `gc dev-pack ask` need to go
# from "what the human typed" to "the bead emit-verdict.sh actually closed and
# mailed" — the same lookup, now shared instead of duplicated. `ask` also has to
# handle a THIRD input shape summary never saw: a follow-up bead id
# (pr-followup.v1), which it walks up via `gc.followup_of` to the same root.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZE="$SCRIPT_DIR/normalize-pr-target.sh"
RIG="vllm"
SPEC=""
RIG_EXPLICIT=0

usage() {
    printf '%s\n' \
        "usage: resolve-verdict-bead.sh <bead-id | PR-number> [--rig N]" \
        "" \
        "Resolve to the root pr-review.v1 / pr-review-quorum.v1 verdict bead." \
        "Prints the bead id on stdout."
}
die() { printf '%s\n' "resolve-verdict-bead: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)     RIG="${2:?--rig needs a value}"; RIG_EXPLICIT=1; shift 2 ;;
        --rig=*)   RIG="${1#*=}"; RIG_EXPLICIT=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --)        shift; break ;;
        -*)        die "unknown option '$1'" ;;
        *)         if [ -z "$SPEC" ]; then SPEC="$1"; shift; else die "unexpected argument '$1'"; fi ;;
    esac
done
[ $# -eq 0 ] || { [ -z "$SPEC" ] && SPEC="$1"; }
[ -n "$SPEC" ] || { usage >&2; die "missing <bead-id | PR-number>"; }
[ -x "$NORMALIZE" ] || die "target normalizer not found/executable: $NORMALIZE"
NORM_ARGS=(--rig "$RIG")
[ "$RIG_EXPLICIT" -eq 1 ] && NORM_ARGS+=(--rig-explicit)
NORM=$("$NORMALIZE" "$SPEC" "${NORM_ARGS[@]}") || exit $?
SPEC=$(printf '%s' "$NORM" | jq -r '.spec')
RIG=$(printf '%s' "$NORM" | jq -r '.rig')

# A bare integer is a PR number: find the ROOT verdict bead (either schema)
# whose canonical gc.output_json.head_ref matches it (also accepting the exact
# same-rig legacy <rig>#N form). A quorum run (N>=2) leaves THREE
# kinds of pr-review*.v1 beads for the same PR — a reviewer-a lane, a
# reviewer-b lane, and the synthesis — and lanes are closed by the very same
# emit-verdict.sh as the synthesis, so "canon" (closed with a review: close
# reason) and "newest timestamp" do NOT distinguish a lane from the synthesis
# (see wo-6xpf: this previously returned a lane's partial verdict, either from
# an index-consistency race right after the run, or structurally whenever a
# later-closing lane retry/dynamic-check outraced the synthesis on timestamp
# alone). The fix: prefer schema=pr-review-quorum.v1 OUTRIGHT over any
# pr-review.v1 lane, never by timestamp; fall back to pr-review.v1 only for
# beads that do NOT carry gc.review_quorum_lane (a genuine N=1 solo run).
# Every formula step ALSO leaves a "logical" mirror bead with the same
# gc.output_json but close_reason=null (not the one emit-verdict.sh actually
# mailed from). Collapse each work/logical pair via gc.logical_bead_id before
# choosing a tier, preferring the canonical emitted work bead within the pair.
#
# Do not use --metadata-field here. That index is eventually consistent, which
# is exactly how a just-finished synthesis used to disappear from this lookup
# while its lanes were already visible. Listing once and filtering the complete
# snapshot locally also prevents the two schema queries from observing
# different points in time.
if printf '%s' "$SPEC" | grep -qE '^[0-9]+$'; then
    N="$SPEC"
    RESULT=$(
        ("$GC" --city "$CITY" --rig "$RIG" bd list --all --json -n 0 2>/dev/null || printf '[]') \
        | jq -c --arg n "$N" --arg rig "$RIG" '
            [ .[]?
              | . as $b
              | ($b.metadata["gc.output_json"] // "" | fromjson?) as $vj
              | select($vj != null
                       and ((($vj.head_ref // "") | tostring) as $head
                            | ($head == $n or $head == ($rig + "#" + $n))))
              | select((($b.metadata["gc.output_json_schema"] // $vj.schema // "")
                        | test("^pr-review(-quorum)?\\.v1$"))
                       or (($b.metadata["gc.review_quorum_role"] // "") == "synthesis"))
              | {id: $b.id,
                 mirror_key: ($b.metadata["gc.logical_bead_id"] // $b.id),
                 ts: ($b.closed_at // $b.updated_at // $b.created_at // ""),
                 canon: (($b.close_reason // "") | test("^(review|dynamic check):")),
                 is_review: (($b.metadata["gc.output_json_schema"] // "") == "pr-review.v1"),
                 is_synthesis: (($b.metadata["gc.output_json_schema"] // "") == "pr-review-quorum.v1"
                                or ($b.metadata["gc.review_quorum_role"] // "") == "synthesis"),
                 is_lane: ($b.metadata["gc.review_quorum_lane"] != null)}
            ] as $all
            | ($all
               | sort_by(.mirror_key)
               | group_by(.mirror_key)
               | map((map(select(.canon))) as $canon
                     | (if ($canon | length) > 0 then $canon else . end)
                     | sort_by(.ts) | last)) as $steps
            | ($steps | map(select(.is_synthesis))) as $synth
            | (if ($synth|length) > 0 then $synth
               else ($steps | map(select(.is_review and (.is_lane | not))))
               end) as $tier
            | if ($tier|length) > 0 then {bead: ($tier | sort_by(.ts) | last | .id), reason: null}
              elif ($all|length) == 0 then {bead: null, reason: "none"}
              else {bead: null, reason: "lanes-only"}
              end' 2>/dev/null || printf '{"bead":null,"reason":"none"}'
    )
    BEAD=$(printf '%s' "$RESULT" | jq -r '.bead // empty' 2>/dev/null || true)
    REASON=$(printf '%s' "$RESULT" | jq -r '.reason // empty' 2>/dev/null || true)
    if [ -z "$BEAD" ]; then
        if [ "$REASON" = "lanes-only" ]; then
            die "PR $N has reviewer-lane verdicts but the quorum synthesis has not finished (or not landed) yet.
Wait for the synthesis mail (subject starts \"PR review\"), then retry — do not ground a follow-up in a lane verdict alone."
        fi
        die "no pr-review verdict bead found for PR $N in rig '$RIG'.
Try --rig <name>, or pass the bead id directly."
    fi
    printf 'resolve-verdict-bead: PR %s -> review bead %s\n' "$N" "$BEAD" >&2
    printf '%s\n' "$BEAD"
    exit 0
fi

# A bead id: walk up gc.followup_of until we land on a root verdict bead (or
# run out of chain — a plain review bead has no gc.followup_of and IS the root).
BEAD="$SPEC"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    SHOW=$("$GC" --city "$CITY" --rig "$RIG" bd show "$BEAD" --json 2>/dev/null) \
        || die "could not read bead '$BEAD' in rig '$RIG' (city '$CITY') — wrong --rig?"
    [ "$(printf '%s' "$SHOW" | jq -r 'length')" -gt 0 ] 2>/dev/null \
        || die "bead '$BEAD' not found in rig '$RIG' (try --rig <name>)"
    PARENT=$(printf '%s' "$SHOW" | jq -r '.[0].metadata["gc.followup_of"] // empty')
    if [ -z "$PARENT" ]; then
        printf '%s\n' "$BEAD"
        exit 0
    fi
    printf 'resolve-verdict-bead: %s is a follow-up of %s\n' "$BEAD" "$PARENT" >&2
    BEAD="$PARENT"
done
die "follow-up chain from '$SPEC' did not resolve to a root bead within 10 hops"
