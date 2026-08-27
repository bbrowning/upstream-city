#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
AUTO="$ROOT/dev-pack/assets/scripts/auto-settle-review.sh"
SELECT="$ROOT/dev-pack/assets/scripts/select-personas.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/repo"

# Real installed compiler/CLI contract on both rigs (read-only): the bounded scope
# flags must be accepted, and direct formula rendering must carry posture/settlement.
for rig in paude vllm; do
  gc --rig "$rig" sling "$rig/pr-review-synthesizer" pr-review-quorum --formula --dry-run \
    --var head_ref=123 --var enable_settle=true --var settle_target="$rig/pr-arbiter" \
    --var triage_target="$rig/pr-triage" --var lane_a_target="$rig/pr-reviewer-a-frontier-xhigh" \
    --var lane_b_target="$rig/pr-reviewer-b-frontier-xhigh" \
    --var synthesis_target="$rig/pr-review-synthesizer" >"$TMP/quorum-$rig"
  gc --rig "$rig" sling "$rig/pr-arbiter" pr-review-settle --formula --dry-run \
    --scope-kind rig --scope-ref "$rig-synth" --var synth_bead="$rig-synth" \
    --var posture=restricted --var effective_posture=restricted --var ceiling_posture=restricted \
    --var arbiter_target="$rig/pr-arbiter" --var resynth_target="$rig/pr-review-synthesizer" \
    >"$TMP/settle-$rig"
  gc --rig "$rig" formula show pr-review-quorum >"$TMP/quorum-show-$rig"
  gc --rig "$rig" formula show pr-review-settle >"$TMP/settle-show-$rig"
  grep -q 'idempotency-guarded settle' "$TMP/quorum-show-$rig" || fail "$rig installed quorum lost auto-settle"
  grep -q 'Exact original quorum effective posture' "$TMP/settle-show-$rig" || fail "$rig installed settle lost posture input"
  grep -q 'FETCH=none' "$ROOT/dev-pack/formulas/pr-review-settle.toml" || fail 'direct settle formula lost posture gate'
done

base_verdict=$(jq -cn '{schema:"pr-review-quorum.v1",head_ref:"123",base_ref:"origin/main",
  implementation_provenance:null,verdict:"request_changes",posture:"limited",
  effective_posture:"limited",ceiling_posture:"limited",summary:"split",
  merge_recommendation:"settle",findings_count:1,
  findings:[{severity:"major",disputed:true}],lanes:[],has_disputed_major:true,
  crux_question:"does the gate hold?",evidence:[],read_only_enforcement:{clean:true,mutations_delta:[]},
  failure_class:"none",failure_reason:""}')
lane_verdict=$(printf '%s' "$base_verdict" | jq -c '.schema="pr-review.v1" | del(.lanes,.has_disputed_major,.crux_question)')
printf '%s\n' "$base_verdict" >"$TMP/state/verdict.json"
printf '%s\n' "$(printf '%s' "$lane_verdict" | jq -c '.posture="trusted" | .effective_posture="trusted" | .ceiling_posture="trusted"')" >"$TMP/state/lane-a.json"
printf '%s\n' "$lane_verdict" >"$TMP/state/lane-b.json"

cat >"$TMP/bin/gc" <<'GC'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_LOG:?}"
args=" $* "
if [[ "$args" == *" bd show synth --json "* ]]; then
  jq -cn --rawfile out "${MOCK_STATE:?}/verdict.json" '[{id:"synth",status:"closed",
    metadata:{"gc.outcome":"pass","gc.output_json_schema":"pr-review-quorum.v1","gc.output_json":($out|rtrimstr("\n"))},
    dependencies:[
      {id:"lane-a",metadata:{"gc.review_quorum_lane":"reviewer-a"}},
      {id:"lane-b",metadata:{"gc.review_quorum_lane":"reviewer-b"}}
    ]}]'
elif [[ "$args" == *" bd show lane-a --json "* || "$args" == *" bd show lane-b --json "* ]]; then
  lane=${args#* bd show }; lane=${lane%% *}
  jq -cn --rawfile out "${MOCK_STATE:?}/$lane.json" '[{metadata:{"gc.output_json":($out|rtrimstr("\n"))}}]'
elif [[ "$args" == *" bd show arc --json "* ]]; then
  printf '%s\n' '[{"id":"arc","status":"open","metadata":{"gc.output_json":"{\"bug_bead\":\"arc\",\"phase\":\"root_cause\",\"rounds\":{\"root_cause\":1,\"fix\":0},\"max_rounds\":3,\"status\":\"report_only\",\"last_reconcile\":{\"n\":2,\"aligned\":true,\"round\":1}}"}}]'
elif [[ "$args" == *" bd list --all --json "* ]]; then
  [ "${MOCK_LIST_FAIL:-0}" = 0 ] || exit 73
  if [ -f "${MOCK_STATE:?}/launched" ]; then printf '%s\n' '[{"id":"settle-root","metadata":{"gc.var.synth_bead":"synth"}}]'; else printf '%s\n' '[]'; fi
elif [[ "$args" == *" sling "* ]]; then
  : >"${MOCK_STATE:?}/launched"
  printf '%s\n' '{"id":"settle-root"}'
else
  printf 'unexpected gc call: %s\n' "$*" >&2
  exit 99
fi
GC
chmod +x "$TMP/bin/gc"
export GC_BIN="$TMP/bin/gc" GC_CITY_PATH="$ROOT" GC_RIG=vllm
export MOCK_LOG="$TMP/gc.log" MOCK_STATE="$TMP/state"

"$AUTO" --synthesis synth --rig vllm --arbiter-target vllm/pr-arbiter \
  --resynth-target vllm/pr-review-synthesizer >/dev/null
grep -q 'sling vllm/pr-arbiter pr-review-settle --formula' "$MOCK_LOG" || fail 'disputed quorum did not launch settle'
for exact in 'head_ref=123' 'base_ref=origin/main' 'synth_bead=synth' \
  'lane_a_bead=lane-a' 'lane_b_bead=lane-b' 'implementation_provenance_json=null' \
  'posture=limited' 'effective_posture=limited' 'ceiling_posture=limited' 'enable_settle=true'; do
  grep -q "$exact" "$MOCK_LOG" || fail "auto-settle lost $exact"
done
grep -q -- '--scope-kind rig --scope-ref synth' "$MOCK_LOG" \
  || fail 'auto-settle launch lacks deterministic synthesis scope'
before=$(grep -c ' sling ' "$MOCK_LOG")
"$AUTO" --synthesis synth --rig vllm >/dev/null
[ "$(grep -c ' sling ' "$MOCK_LOG")" -eq "$before" ] || fail 'second auto-settle call launched a loop'

rm "$TMP/state/launched"
jq '.has_disputed_major=false | .findings[0].disputed=false' "$TMP/state/verdict.json" >"$TMP/state/verdict.next"
mv "$TMP/state/verdict.next" "$TMP/state/verdict.json"
"$AUTO" --synthesis synth --rig vllm >/dev/null
[ ! -f "$TMP/state/launched" ] || fail 'nondisputed quorum launched settlement'

jq '.has_disputed_major=true | .findings[0].disputed=true' "$TMP/state/verdict.json" >"$TMP/state/verdict.next"
mv "$TMP/state/verdict.next" "$TMP/state/verdict.json"
jq '.implementation_provenance={artifact_id:"drift"}' "$TMP/state/lane-a.json" >"$TMP/state/lane.next"
mv "$TMP/state/lane.next" "$TMP/state/lane-a.json"
if "$AUTO" --synthesis synth --rig vllm >/dev/null 2>&1; then
  fail 'auto-settle accepted lane/synthesis posture drift'
fi
[ ! -f "$TMP/state/launched" ] || fail 'provenance/posture mismatch launched settlement'

status=$("$ROOT/dev-pack/commands/status/run.sh" arc --rig vllm)
printf '%s' "$status" | grep -q 'status:            report_only' \
  || fail 'terminal report-only arc rendered as running'

# The selector must work with no local environment and may write only its city cache.
git -C "$TMP/repo" init -q
printf '%s\n' tracked >"$TMP/repo/tracked"
printf '%s\n' '.venv/' >"$TMP/repo/.gitignore"
git -C "$TMP/repo" add tracked .gitignore
git -C "$TMP/repo" -c user.name=test -c user.email=test@example.invalid commit -qm init
cat >"$TMP/bin/uv" <<'UV'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
[[ "$args" == *" --no-project "* ]] || exit 90
cache=""; while [ $# -gt 0 ]; do
  case "$1" in --cache-dir) cache=$2; shift 2;; run|--no-project|--no-sync) shift;; --python) shift 2;; *) break;; esac
done
[[ "$cache" == *"/.gc/runtime/"* ]] || exit 91
if [ "${MOCK_UV_MUTATE_FAIL:-0}" = 1 ]; then mkdir -p .venv; printf '%s\n' leaked >.venv/marker; exit 72; fi
exec python3 "$@"
UV
chmod +x "$TMP/bin/uv"
before=$(git -C "$TMP/repo" status --porcelain=v1)
(cd "$TMP/repo" && GC_PERSONA_UV="$TMP/bin/uv" GC_PERSONAS="$ROOT/tools/vllm/personas" \
  "$SELECT" --corpus "$ROOT/tools/vllm/personas" --lens settle --path vllm/parser/qwen3.py) \
  | grep -q 'base.md' || fail 'external selector did not load base persona'
[ ! -e "$TMP/repo/.venv" ] || fail 'persona selection created a local .venv'
[ "$(git -C "$TMP/repo" status --porcelain=v1)" = "$before" ] || fail 'persona selection dirtied worktree'

if command -v uv >/dev/null 2>&1; then
  (cd "$TMP/repo" && GC_PERSONAS="$ROOT/tools/vllm/personas" \
    "$SELECT" --corpus "$ROOT/tools/vllm/personas" --lens settle --path vllm/parser/qwen3.py) \
    >/dev/null || fail 'real uv missing-.venv selector path failed'
  [ ! -e "$TMP/repo/.venv" ] || fail 'real uv selector created a local .venv'
fi
if (cd "$TMP/repo" && GC_PERSONA_UV="$TMP/bin/uv" GC_PERSONA_CACHE_DIR="$TMP/repo/.venv" \
    "$SELECT" --corpus "$ROOT/tools/vllm/personas" --lens settle --path vllm/parser/qwen3.py) \
    >/dev/null 2>&1; then
  fail 'selector accepted a worktree-local cache override'
fi
[ ! -e "$TMP/repo/.venv" ] || fail 'rejected local cache override still created .venv'
if (cd "$TMP/repo" && MOCK_UV_MUTATE_FAIL=1 GC_PERSONA_UV="$TMP/bin/uv" \
    "$SELECT" --corpus "$ROOT/tools/vllm/personas" --lens settle --path vllm/parser/qwen3.py) \
    >/dev/null 2>"$TMP/selector-failure.err"; then
  fail 'failing selector mutation unexpectedly succeeded'
fi
grep -q 'selector mutated the target worktree' "$TMP/selector-failure.err" \
  || fail 'failure-path ignored .venv mutation escaped baseline enforcement'
rm -rf "$TMP/repo/.venv"
printf '%s\n' dirty >"$TMP/repo/tracked"
if (cd "$TMP/repo" && GC_PERSONA_UV="$TMP/bin/uv" \
    "$SELECT" --corpus "$ROOT/tools/vllm/personas" --lens settle --path vllm/parser/qwen3.py) \
    >/dev/null 2>&1; then
  fail 'selector accepted a dirty read-only baseline'
fi
git -C "$TMP/repo" restore tracked

MOCK_LIST_FAIL=1
export MOCK_LIST_FAIL
if "$AUTO" --synthesis synth --rig vllm >/dev/null 2>&1; then
  fail 'auto-settle failed open when durable idempotency listing failed'
fi
unset MOCK_LIST_FAIL
[ ! -f "$TMP/state/launched" ] || fail 'list failure launched a duplicate settlement'

# Coordinator instructions and helper use the concrete safety-approved cleanup.
grep -Fq 'unlink "$state_file"' "$ROOT/dev-pack/agents/bug-coordinator/prompt.template.md" \
  || fail 'coordinator state cleanup is not unlink based'
grep -Fq "trap 'unlink -- \"\$JF\"" "$ROOT/dev-pack/assets/scripts/emit-json.sh" \
  || fail 'emit-json consume cleanup is not unlink based'
! rg -n 'rm -f' "$ROOT/dev-pack/agents/bug-coordinator" "$ROOT/dev-pack/formulas/hard-bug-"* >/dev/null \
  || fail 'hard-bug execution guidance still contains rm -f'
for phrase in 'Set `has_disputed_major=false` only' 'explicitly escalate to the human' \
  'Never sling another settle round' 'preserve its exact head/base'; do
  grep -Fq "$phrase" "$ROOT/dev-pack/formulas/pr-review-settle.toml" \
    || fail "final re-synthesis contract missing: $phrase"
done

refuted=$(jq -cn '{head_ref:"123",settle_of:"synth",settled_verdict:"approve",
  disputes_examined:1,resolutions:[{resolution:"refuted",title:"not a defect"}],summary:"done",
  failure_class:"none",failure_reason:""}' | \
  "$ROOT/dev-pack/assets/scripts/render-verdict.sh" - --brief)
printf '%s' "$refuted" | grep -q '1 refuted' || fail 'direct settle render hides refuted findings'

# Execute the complete report-only terminal transition: persist terminal state,
# keep the investigation open, close/notify the step, consume temps, and never sling.
cat >"$TMP/bin/gc-hardbug" <<'HGC'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${HB_LOG:?}"
if [ "${1-} ${2-} ${3-}" = "bd show arc" ]; then
  if [ -f "${HB_STATE:?}/arc.json" ]; then raw=$(cat "${HB_STATE}/arc.json"); else raw='{"bug_bead":"arc","status":"running"}'; fi
  [ "${HB_CORRUPT_READBACK:-0}" = 0 ] || raw=$(printf '%s' "$raw" | jq -c 'del(.phase)')
  jq -cn --arg raw "$raw" '[{id:"arc",status:"open",metadata:{"gc.output_json":$raw}}]'
elif [ "${1-} ${2-} ${3-}" = "bd update arc" ]; then
  pair=$5; printf '%s\n' "${pair#gc.output_json=}" >"${HB_STATE:?}/arc.json"
elif [ "${1-} ${2-} ${3-}" = "bd show step" ]; then
  metadata='{}'; [ ! -f "${HB_STATE:?}/step.json" ] || metadata=$(cat "${HB_STATE}/step.json")
  jq -cn --argjson metadata "$metadata" '[{id:"step",status:"open",metadata:$metadata}]'
elif [ "${1-} ${2-} ${3-}" = "bd update step" ]; then
  shift 3; state="${HB_STATE:?}/step.json"; [ -f "$state" ] || printf '%s\n' '{}' >"$state"
  while [ $# -gt 0 ]; do
    if [ "$1" = --set-metadata ]; then
      pair=$2; key=${pair%%=*}; value=${pair#*=}; jq --arg k "$key" --arg v "$value" '.+{($k):$v}' "$state" >"$state.next"; mv "$state.next" "$state"; shift 2
    else shift; fi
  done
elif [ "${1-} ${2-} ${3-}" = "bd close step" ]; then
  : >"${HB_STATE:?}/step.closed"
elif [ "${1-} ${2-}" = "mail send" ]; then
  printf '%s\n' '{"id":"mail-1"}'
elif [ "${1-} ${2-}" = "runtime drain" ]; then
  :
else
  printf 'unexpected hardbug gc call: %s\n' "$*" >&2; exit 99
fi
HGC
chmod +x "$TMP/bin/gc-hardbug"
jq -cn '{phase:"root_cause",round:1,n:2,subject:"arc",aligned:true,
  stronger_lane:"lane-a",next_action:"report_only",report:{root_cause:"cause"},
  failure_class:"none",failure_reason:""}' >"$TMP/reconcile.json"
jq -cn '{bug_bead:"arc",phase:"root_cause",rounds:{root_cause:1,fix:0},max_rounds:3,
  status:"running",last_reconcile:{n:2,aligned:true,round:1}}' >"$TMP/arc-state.json"
HB_LOG="$TMP/hardbug.log" HB_STATE="$TMP/state" GC_BIN="$TMP/bin/gc-hardbug" \
  GC_AGENT=vllm/bug-coordinator GC_HARDBUG_NOTIFY_TO=human \
  "$ROOT/dev-pack/assets/scripts/complete-hardbug-report-only.sh" \
  --arc arc --step step --verdict-file "$TMP/reconcile.json" \
  --state-file "$TMP/arc-state.json" --subject report-only
jq -e '.status=="report_only"' "$TMP/state/arc.json" >/dev/null \
  || fail 'report-only coordinator sequence did not persist terminal state'
[ -f "$TMP/state/step.closed" ] || fail 'report-only reconcile step did not close'
[ ! -e "$TMP/reconcile.json" ] && [ ! -e "$TMP/arc-state.json" ] \
  || fail 'report-only coordinator sequence leaked temp files'
! grep -q ' sling ' "$TMP/hardbug.log" || fail 'report-only terminal sequence launched fix/finalize work'
grep -q 'bd show arc --json' "$TMP/hardbug.log" || fail 'report-only sequence did not verify open human-follow-up arc'

# A drifted durable readback must fail closed and still consume both coordinator
# inputs, even though emit-json never receives the verdict on this path.
jq -cn '{phase:"root_cause",round:1,n:2,subject:"arc",aligned:true,
  stronger_lane:"lane-a",next_action:"report_only",report:{root_cause:"cause"},
  failure_class:"none",failure_reason:""}' >"$TMP/reconcile-corrupt.json"
jq -cn '{bug_bead:"arc",phase:"root_cause",rounds:{root_cause:1,fix:0},max_rounds:3,
  status:"running",last_reconcile:{n:2,aligned:true,round:1}}' >"$TMP/arc-state-corrupt.json"
if HB_CORRUPT_READBACK=1 HB_LOG="$TMP/hardbug.log" HB_STATE="$TMP/state" \
  GC_BIN="$TMP/bin/gc-hardbug" GC_AGENT=vllm/bug-coordinator \
  "$ROOT/dev-pack/assets/scripts/complete-hardbug-report-only.sh" \
  --arc arc --step step --verdict-file "$TMP/reconcile-corrupt.json" \
  --state-file "$TMP/arc-state-corrupt.json" >/dev/null 2>&1; then
  fail 'report-only coordinator accepted a corrupted durable readback'
fi
[ ! -e "$TMP/reconcile-corrupt.json" ] && [ ! -e "$TMP/arc-state-corrupt.json" ] \
  || fail 'report-only failure path leaked coordinator temp files'

# Cleanup begins as soon as input paths are parsed, even when required routing
# arguments are missing and neither file can reach the emitter.
printf '%s\n' '{}' >"$TMP/reconcile-invalid.json"
printf '%s\n' '{}' >"$TMP/arc-state-invalid.json"
if "$ROOT/dev-pack/assets/scripts/complete-hardbug-report-only.sh" \
  --verdict-file "$TMP/reconcile-invalid.json" \
  --state-file "$TMP/arc-state-invalid.json" >/dev/null 2>&1; then
  fail 'report-only helper accepted missing arc and step arguments'
fi
[ ! -e "$TMP/reconcile-invalid.json" ] && [ ! -e "$TMP/arc-state-invalid.json" ] \
  || fail 'report-only argument-validation failure leaked coordinator temp files'

printf 'workflow polish: ok\n'
