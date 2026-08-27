#!/usr/bin/env bash
# Launch exactly one settlement workflow for a successful disputed quorum.
# All decisions are made from durable schema output; repeated calls are no-ops.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
RIG="${GC_RIG:-}" ; SYNTH="" ; ARBITER="" ; RESYNTH="" ; DRY_RUN=false
die() { printf 'auto-settle: %s\n' "$*" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --synthesis) SYNTH="${2:?}"; shift 2 ;;
        --synthesis=*) SYNTH="${1#*=}"; shift ;;
        --rig) RIG="${2:?}"; shift 2 ;;
        --rig=*) RIG="${1#*=}"; shift ;;
        --arbiter-target) ARBITER="${2:?}"; shift 2 ;;
        --arbiter-target=*) ARBITER="${1#*=}"; shift ;;
        --resynth-target) RESYNTH="${2:?}"; shift 2 ;;
        --resynth-target=*) RESYNTH="${1#*=}"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) die "unknown argument '$1'" ;;
    esac
done
[ -n "$SYNTH" ] || die "--synthesis is required"
[ -n "$RIG" ] || RIG="${SYNTH%-*}"
[ -n "$ARBITER" ] || ARBITER="$RIG/pr-arbiter"
[ -n "$RESYNTH" ] || RESYNTH="$RIG/pr-review-synthesizer"
[[ "$ARBITER" == "$RIG/"* && "$RESYNTH" == "$RIG/"* ]] || die "targets must belong to rig '$RIG'"

show=$("$GC" --city "$CITY" --rig "$RIG" bd show "$SYNTH" --json) || die "cannot read synthesis '$SYNTH'"
printf '%s' "$show" | jq -e '
  .[0] | .status == "closed" and .metadata["gc.outcome"] == "pass" and
  .metadata["gc.output_json_schema"] == "pr-review-quorum.v1"' >/dev/null \
  || die "synthesis must be a successful closed pr-review-quorum.v1 attempt"
verdict=$(printf '%s' "$show" | jq -cer '.[0].metadata["gc.output_json"] | fromjson')
if ! printf '%s' "$verdict" | jq -e '
  .has_disputed_major == true and
  any(.findings[]?; .disputed == true and
      (.severity == "blocker" or .severity == "major" or .severity == "critical"))' >/dev/null; then
    printf 'auto-settle: no disputed major/critical finding; no settlement launched\n' >&2
    exit 0
fi

mapfile -t lanes < <(printf '%s' "$show" | jq -r '
  [.[0].dependencies[]? | select(.metadata["gc.review_quorum_lane"] != null)]
  | sort_by(.metadata["gc.review_quorum_lane"]) | .[].id')
[ "${#lanes[@]}" -eq 2 ] || die "expected exactly two reviewer lane dependencies"
lane_payloads=()
for lane in "${lanes[@]}"; do
    lane_json=$("$GC" --city "$CITY" --rig "$RIG" bd show "$lane" --json \
        | jq -cer '.[0].metadata["gc.output_json"] | fromjson') || die "cannot read lane '$lane'"
    jq -en --argjson synth "$verdict" --argjson lane "$lane_json" '
      $lane.implementation_provenance == $synth.implementation_provenance' >/dev/null \
      || die "lane '$lane' does not exactly match synthesis provenance"
    lane_payloads+=("$lane_json")
done
lanes_json=$(printf '%s\n' "${lane_payloads[@]}" | jq -cs .)
jq -en --argjson synth "$verdict" --argjson lanes "$lanes_json" '
  def rank: {block:0, restricted:1, limited:2, trusted:3}[.] // error("bad posture");
  all(["posture", "effective_posture", "ceiling_posture"][];
      . as $field |
      ($synth[$field] | rank) == ([$lanes[][$field] | rank] | min))' >/dev/null \
  || die "synthesis posture fields are not the most restrictive lane values"

all_beads=$("$GC" --city "$CITY" --rig "$RIG" bd list --all --json -n 0) \
    || die "cannot prove whether a settlement already exists for '$SYNTH'"
existing=$(printf '%s' "$all_beads" | jq -c --arg synth "$SYNTH" \
    '[.[] | select(.metadata["gc.var.synth_bead"] == $synth)]')
if [ "$(printf '%s' "$existing" | jq 'length')" -gt 0 ]; then
    printf 'auto-settle: settlement already exists for %s; no-op\n' "$SYNTH" >&2
    exit 0
fi

head_ref=$(printf '%s' "$verdict" | jq -er '.head_ref')
base_ref=$(printf '%s' "$verdict" | jq -er '.base_ref')
crux=$(printf '%s' "$verdict" | jq -er '.crux_question')
provenance=$(printf '%s' "$verdict" | jq -c '.implementation_provenance')
posture=$(printf '%s' "$verdict" | jq -er '.posture')
effective=$(printf '%s' "$verdict" | jq -er '.effective_posture')
ceiling=$(printf '%s' "$verdict" | jq -er '.ceiling_posture')
args=("$ARBITER" pr-review-settle --formula
    --scope-kind rig --scope-ref "$SYNTH"
    --var "head_ref=$head_ref" --var "base_ref=$base_ref"
    --var "synth_bead=$SYNTH" --var "lane_a_bead=${lanes[0]}" --var "lane_b_bead=${lanes[1]}"
    --var "crux_question=$crux" --var "arbiter_target=$ARBITER" --var "resynth_target=$RESYNTH"
    --var "enable_settle=true" --var "implementation_provenance_json=$provenance"
    --var "posture=$posture" --var "effective_posture=$effective" --var "ceiling_posture=$ceiling"
    --title "pr-review-settle: $head_ref" --json)
if [ "$DRY_RUN" = true ]; then
    printf '%q ' "$GC" --city "$CITY" --rig "$RIG" sling "${args[@]}"
    printf '\n'
    exit 0
fi
"$GC" --city "$CITY" --rig "$RIG" sling "${args[@]}"
