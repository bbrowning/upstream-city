#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
EMIT="$ROOT/dev-pack/assets/scripts/emit-review.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/state"
cat >"$TMP/bin/gc" <<'GC'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_GC_LOG:?}"
if [ "${1-} ${2-}" = "--city ${GC_CITY_PATH:-}" ] && [ "${3-} ${4-} ${5-}" = "rig list --json" ]; then
  printf '%s\n' '{"rigs":[{"name":"vllm"}]}'
elif [ "${1-} ${2-}" = "bd update" ]; then
  bead=$3; shift 3
  state="${MOCK_GC_STATE:?}/$bead.json"
  [ -f "$state" ] || printf '%s\n' '{}' >"$state"
  while [ $# -gt 0 ]; do
    if [ "$1" = "--set-metadata" ]; then
      pair=$2; key=${pair%%=*}; value=${pair#*=}
      next="$state.next"
      jq --arg key "$key" --arg value "$value" '. + {($key):$value}' "$state" >"$next"
      mv "$next" "$state"
      shift 2
    else
      shift
    fi
  done
elif [ "${1-} ${2-}" = "bd show" ]; then
  if [ "${3-}" = "${MOCK_LOGICAL_BEAD:-}" ]; then
    jq -cn --arg logical "${MOCK_LOGICAL_BEAD}" --arg attempt "${MOCK_ATTEMPT_BEAD:?}" \
      '[{status:"open",metadata:{"gc.kind":"retry"},dependencies:[
        {id:"workflow-root",status:"open",metadata:{"gc.kind":"workflow"},dependency_type:"tracks"},
        {id:"previous-attempt",status:"closed",metadata:{"gc.logical_bead_id":$logical,"gc.attempt":"1"},dependency_type:"blocks"},
        {id:$attempt,status:"open",metadata:{"gc.logical_bead_id":$logical,"gc.attempt":"2"},dependency_type:"blocks"}
      ]}]'
    exit 0
  fi
  state="${MOCK_GC_STATE:?}/$3.json"
  if [ ! -f "$state" ]; then
    printf '%s\n' '[{"status":"open","metadata":{}}]'
    exit 0
  fi
  metadata=$(cat "$state")
  if [ "${MOCK_TRUNCATE:-0}" = 1 ]; then
    metadata=$(printf '%s' "$metadata" | jq '."gc.output_json" = "{"')
  fi
  jq -cn --argjson metadata "$metadata" '[{metadata:$metadata}]'
elif [ "${1-} ${2-}" = "bd close" ]; then
  :
else
  printf 'unexpected gc call: %s\n' "$*" >&2
  exit 99
fi
GC
chmod +x "$TMP/bin/gc"

export GC_BIN="$TMP/bin/gc"
export GC_CITY_PATH="$ROOT"
export GC_RIG=vllm
export GC_PR_NOTIFY_TO=''
export MOCK_GC_LOG="$TMP/gc.log"
export MOCK_GC_STATE="$TMP/state"

emit() {
  local bead=$1 schema=$2
  python3 "$EMIT" --bead "$bead" --schema "$schema" --outcome pass
}

triage=$(jq -cn --arg rationale "The author's change is safe" \
  '{schema:"pr-triage.v1",posture:"trusted",ceiling_posture:"trusted",
  rationale:$rationale,allowed_actions:[],facts:[],base_ref:"main",
  head_ref:"feature/safe",failure_class:"none",failure_reason:""}')
printf '%s\n' "$triage" | emit triage pr-triage.v1
grep -q 'bd close triage' "$MOCK_GC_LOG" || fail "triage did not close"
jq -e --arg expected "The author's change is safe" \
  '."gc.output_json" | fromjson | .rationale == $expected' \
  "$TMP/state/triage.json" >/dev/null || fail "apostrophe did not survive triage emission"

review=$(jq -cn --arg summary "It's ready" \
  '{schema:"pr-review.v1",head_ref:"feature/safe",base_ref:"main",
  implementation_provenance:null,verdict:"approve",posture:"trusted",effective_posture:"trusted",
  ceiling_posture:"trusted",summary:$summary,merge_recommendation:"merge",findings_count:0,
  findings:[],dynamic_check:"not_needed",dynamic_request:null,evidence:[],
  read_only_enforcement:{clean:true,mutations_delta:[]},failure_class:"none",failure_reason:""}')
printf '%s\n' "$review" | emit review pr-review.v1
grep -q 'bd close review' "$MOCK_GC_LOG" || fail "review did not close"
jq -e --arg expected "It's ready" '."gc.output_json" | fromjson | .summary == $expected' \
  "$TMP/state/review.json" >/dev/null || fail "apostrophe did not survive review emission"

quorum=$(jq -cn --arg summary "Both lanes agree it's ready" \
  '{schema:"pr-review-quorum.v1",head_ref:"feature/safe",base_ref:"main",
  implementation_provenance:null,verdict:"approve",posture:"trusted",effective_posture:"trusted",
  ceiling_posture:"trusted",summary:$summary,merge_recommendation:"merge",
  findings_count:0,findings:[],lanes:[],evidence:[],
  read_only_enforcement:{clean:true,mutations_delta:[]},failure_class:"none",failure_reason:""}')
printf '%s\n' "$quorum" | emit synthesis pr-review-quorum.v1
grep -q 'bd close synthesis' "$MOCK_GC_LOG" || fail "synthesis did not close"

# Agents can be handed the retry control/logical bead while its current attempt is
# the actual executable unit. Every review role must finish that open attempt and
# leave logical closure to the controller, which mirrors the terminal attempt.
assert_logical_attempt_close() {
  local logical=$1 attempt=$2 schema=$3 payload=$4
  : >"$MOCK_GC_LOG"
  export MOCK_LOGICAL_BEAD=$logical MOCK_ATTEMPT_BEAD=$attempt
  printf '%s\n' "$payload" | emit "$logical" "$schema"
  grep -q "bd update $attempt" "$MOCK_GC_LOG" \
    || fail "$schema did not write the active attempt"
  grep -q "bd close $attempt" "$MOCK_GC_LOG" \
    || fail "$schema did not close the active attempt"
  ! grep -q "bd update $logical" "$MOCK_GC_LOG" \
    || fail "$schema wrote result metadata to the logical retry bead"
  ! grep -q "bd close $logical" "$MOCK_GC_LOG" \
    || fail "$schema closed the logical retry bead directly"
  unset MOCK_LOGICAL_BEAD MOCK_ATTEMPT_BEAD
}
assert_logical_attempt_close logical-triage attempt-triage pr-triage.v1 "$triage"
assert_logical_attempt_close logical-review attempt-review pr-review.v1 "$review"
assert_logical_attempt_close logical-synthesis attempt-synthesis pr-review-quorum.v1 "$quorum"

before=$(wc -l <"$MOCK_GC_LOG")
if printf '' | emit empty pr-triage.v1 >/dev/null 2>&1; then fail "empty stdin passed"; fi
if printf '%s\n' '{"schema":"pr-review.v1"}' | emit invalid pr-review.v1 >/dev/null 2>&1; then
  fail "incomplete schema passed"
fi
if printf '%s\n' "$review" | python3 "$EMIT" --bead mismatch --schema pr-review.v1 \
    --outcome fail --failure-class transient --failure-reason provider-down >/dev/null 2>&1; then
  fail "mismatched JSON/CLI failure metadata passed"
fi
[ "$(wc -l <"$MOCK_GC_LOG")" -eq "$before" ] || fail "invalid input called gc"

if printf '%s\n' "$review" | MOCK_TRUNCATE=1 emit truncated pr-review.v1 >/dev/null 2>&1; then
  fail "truncated readback passed"
fi
grep -q 'bd update truncated' "$MOCK_GC_LOG" || fail "truncation case did not write"
! grep -q 'bd close truncated' "$MOCK_GC_LOG" || fail "truncated storage closed"

if rg -n 'rm -f' "$ROOT/dev-pack/agents" "$ROOT/dev-pack/formulas" \
    --glob '*.md' --glob '*.toml' >/dev/null; then
  fail "a workflow prompt still prescribes rm -f"
fi
rg -q "<<'JSON'" "$ROOT/dev-pack/agents/pr-triage/prompt.template.md" \
  || fail "triage prompt does not prescribe quoted JSON stdin"

printf 'review verdict emission: ok\n'
