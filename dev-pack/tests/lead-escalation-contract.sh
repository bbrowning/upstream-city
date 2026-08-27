#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ROUTE="$ROOT/dev-pack/assets/scripts/escalate-rig-work.sh"
MAYOR="$ROOT/dev-pack/assets/scripts/escalate-rig-work-to-mayor.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP/bin"
printf '%s\n' '{"status":"open","metadata":{}}' >"$TMP/state.json"
: >"$TMP/gc.log"
cat >"$TMP/bin/gc" <<'GC'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${MOCK_GC_LOG:?}"; printf '\n' >>"$MOCK_GC_LOG"
while [ $# -gt 0 ]; do case "$1" in --city|--rig) shift 2 ;; *) break ;; esac; done
case "${1-} ${2-}" in
  "bd show") jq -c '[.]' "${MOCK_GC_STATE:?}" ;;
  "bd update")
    shift 3; next="${MOCK_GC_STATE}.next"; cp "$MOCK_GC_STATE" "$next"
    while [ $# -gt 0 ]; do
      case "$1" in
        --set-metadata) pair=$2; key=${pair%%=*}; value=${pair#*=}; jq --arg k "$key" --arg v "$value" '.metadata[$k]=$v' "$next" >"$next.tmp"; mv "$next.tmp" "$next"; shift 2 ;;
        --status) jq --arg v "$2" '.status=$v' "$next" >"$next.tmp"; mv "$next.tmp" "$next"; shift 2 ;;
        *) shift ;;
      esac
    done
    mv "$next" "$MOCK_GC_STATE" ;;
  "bd set-state") : ;;
  "mail send") : ;;
  *) printf 'unexpected gc call: %s\n' "$*" >&2; exit 99 ;;
esac
GC
chmod +x "$TMP/bin/gc"
export GC_BIN="$TMP/bin/gc" GC_CITY_PATH="$ROOT" MOCK_GC_LOG="$TMP/gc.log" MOCK_GC_STATE="$TMP/state.json"

route_paude() {
  "$ROUTE" --rig paude --work-bead paude-feature-1 --workflow change-lifecycle \
    --reason revision-bound-exhausted --phase review --iteration 3 \
    --branch feature/paude-feature-1 --head-sha deadbeef --artifact-id artifact-3 \
    --evidence-beads 'review-a,review-b,synthesis,settlement'
}
route_paude >"$TMP/paude.json"
jq -e '.schema == "rig-lead-escalation.v1" and .rig == "paude" and .lead == "paude/lead" and
  .iteration == 3 and .head_sha == "deadbeef" and .artifact_id == "artifact-3" and
  (.evidence_beads | sort == ["review-a","review-b","settlement","synthesis"]) and .notified' "$TMP/paude.json" >/dev/null
grep -q 'mail send paude/lead .*--notify' "$TMP/gc.log" || fail 'paude lead was not notified/woken'
! grep -q 'hold=mayor\|hold=lead' "$TMP/gc.log" || fail 'routine lead route applied a hold'

# A completed replay returns the durable object without duplicating mail.
route_paude >"$TMP/paude-replay.json"
[ "$(grep -c 'mail send paude/lead' "$TMP/gc.log")" -eq 1 ] || fail 'replay duplicated paude lead mail'

# The same contract resolves a second real rig name for hard-bug convergence evidence.
printf '%s\n' '{"status":"open","metadata":{}}' >"$TMP/state.json"
"$ROUTE" --rig vllm --work-bead vllm-bug-1 --workflow hard-bug-convergence \
  --reason cap-exhausted --phase fix --iteration 4 --branch '' --head-sha '' --artifact-id '' \
  --evidence-beads 'lane-a-4,lane-b-4,reconcile-4' >"$TMP/vllm.json"
jq -e '.rig == "vllm" and .lead == "vllm/lead" and .phase == "fix" and .iteration == 4 and
  .branch == null and .head_sha == null and .artifact_id == null and (.evidence_beads | length == 3)' "$TMP/vllm.json" >/dev/null
grep -q 'mail send vllm/lead .*--notify' "$TMP/gc.log" || fail 'vllm lead was not notified/woken'

# Only the explicit second tier may add the sanctioned mayor hold and mayor notification.
"$MAYOR" --rig vllm --work-bead vllm-bug-1 --decision-kind resource \
  --reason 'needs another high-cost reviewer slot' >"$TMP/mayor.json"
jq -e '.schema == "mayor-escalation.v1" and .decision_kind == "resource" and .notified and
  .lead_escalation.schema == "rig-lead-escalation.v1"' "$TMP/mayor.json" >/dev/null
grep -q 'bd set-state vllm-bug-1 hold=mayor' "$TMP/gc.log" || fail 'second tier did not apply mayor hold'
grep -q 'mail send mayor .*--notify' "$TMP/gc.log" || fail 'second tier did not notify/wake mayor'
! grep -q 'hold=lead' "$TMP/gc.log" || fail 'unsupported hold:lead was introduced'

printf 'lead escalation contract: ok\n'
