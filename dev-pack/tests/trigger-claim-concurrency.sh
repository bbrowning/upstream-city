#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CLAIM="$ROOT/dev-pack/assets/scripts/claim-trigger.sh"
EMIT_JSON="$ROOT/dev-pack/assets/scripts/emit-json.sh"
EMIT_REVIEW="$ROOT/dev-pack/assets/scripts/emit-review.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/work-a" "$TMP/work-b" "$TMP/runtime"
printf '%s\n' '{}' >"$TMP/state/lane-a.json"
printf '%s\n' '{}' >"$TMP/state/lane-b.json"

cat >"$TMP/bin/gc" <<'GC'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${MOCK_STATE:?}
cmd=${1-}; sub=${2-}; bead=${3-}
if [ "$cmd $sub" = "bd show" ]; then
  state="$state_dir/$bead.json"
  [ -f "$state" ] || printf '%s\n' '{}' >"$state"
  metadata=$(cat "$state")
  assignee=$(printf '%s' "$metadata" | jq -r '.assignee // empty')
  route=$(printf '%s' "$metadata" | jq -r '.route // empty')
  body=$(printf '%s' "$metadata" | jq 'del(.assignee,.route)')
  jq -cn --arg id "$bead" --arg assignee "$assignee" --arg route "$route" --argjson metadata "$body" \
    '[{id:$id,status:"open",assignee:(if $assignee=="" then null else $assignee end),metadata:($metadata + (if $route=="" then {} else {"gc.routed_to":$route} end))}]'
elif [ "$cmd $sub" = "bd update" ]; then
  state="$state_dir/$bead.json"
  exec 9>"$state_dir/state.lock"; flock -x 9
  [ -f "$state" ] || printf '%s\n' '{}' >"$state"
  current=$(cat "$state")
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --claim) current=$(printf '%s' "$current" | jq --arg owner "${GC_SESSION_NAME:-}" '.assignee=$owner'); shift ;;
      --set-metadata) pair=$2; key=${pair%%=*}; value=${pair#*=}; current=$(printf '%s' "$current" | jq --arg k "$key" --arg v "$value" '.[$k]=$v'); shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s\n' "$current" >"$state.next"; mv "$state.next" "$state"
  printf '%s\t%s\t%s\n' "${GC_SESSION_NAME:-}" "$bead" "$current" >>"${MOCK_LOG:?}"
elif [ "$cmd $sub" = "bd close" ]; then
  printf 'close\t%s\n' "$bead" >>"${MOCK_LOG:?}"
elif [ "$cmd $sub" = "runtime drain" ]; then
  :
elif [ "$cmd $sub" = "mail send" ]; then
  printf '%s\n' '{"id":"mail"}'
else
  printf 'unexpected gc call: %s\n' "$*" >&2
  exit 99
fi
GC
chmod +x "$TMP/bin/gc"
export GC_BIN="$TMP/bin/gc" MOCK_STATE="$TMP/state" MOCK_LOG="$TMP/gc.log"
export GC_CITY_RUNTIME_DIR="$TMP/runtime" GC_PR_NOTIFY_TO=''

# Two dispatches in the same pool generation claim only their controller-selected
# ids. The stale stamps seeded here must be repaired on those exact beads.
jq -cn '{route:"rig/worker-a","gc.session_name":"stale","gc.work_dir":"/stale"}' >"$TMP/state/lane-a.json"
jq -cn '{route:"rig/worker-b","gc.session_name":"stale","gc.work_dir":"/stale"}' >"$TMP/state/lane-b.json"
(
  cd "$TMP/work-a"
  GC_TRIGGER_BEAD_ID=lane-a GC_AGENT=rig/worker-a GC_SESSION_NAME=session-a \
    GC_SESSION_ORIGIN=ephemeral "$CLAIM" >"$TMP/claim-a"
) & p1=$!
(
  cd "$TMP/work-b"
  GC_TRIGGER_BEAD_ID=lane-b GC_AGENT=rig/worker-b GC_SESSION_NAME=session-b \
    GC_SESSION_ORIGIN=ephemeral "$CLAIM" >"$TMP/claim-b"
) & p2=$!
wait "$p1"; wait "$p2"
[ "$(cat "$TMP/claim-a")" = lane-a ] || fail 'worker A did not bind lane-a'
[ "$(cat "$TMP/claim-b")" = lane-b ] || fail 'worker B did not bind lane-b'
jq -e --arg dir "$TMP/work-a" '.assignee=="session-a" and .["gc.session_name"]=="session-a" and .["gc.work_dir"]==$dir' "$TMP/state/lane-a.json" >/dev/null \
  || fail 'lane-a ownership/provenance was not repaired'
jq -e --arg dir "$TMP/work-b" '.assignee=="session-b" and .["gc.session_name"]=="session-b" and .["gc.work_dir"]==$dir' "$TMP/state/lane-b.json" >/dev/null \
  || fail 'lane-b ownership/provenance was not repaired'

# A route/trigger mismatch is rejected before claim and before provenance repair.
: >"$TMP/gc.log"
if (cd "$TMP/work-a"; GC_TRIGGER_BEAD_ID=lane-a GC_AGENT=rig/worker-b GC_SESSION_NAME=intruder \
    GC_SESSION_ORIGIN=ephemeral "$CLAIM" >/dev/null 2>&1); then
  fail 'foreign-routed trigger was claimable'
fi
[ ! -s "$TMP/gc.log" ] || fail 'foreign-routed trigger caused a mutation'

run_json_race() {
  local schema=$1 bead=$2
  printf '%s\n' '{}' >"$TMP/state/$bead.json"
  printf '{"schema":"%s","writer":"a"}\n' "$schema" >"$TMP/a.json"
  printf '{"schema":"%s","writer":"b"}\n' "$schema" >"$TMP/b.json"
  set +e
  (cd "$TMP/work-a"; GC_TRIGGER_BEAD_ID="$bead" GC_SESSION_ORIGIN=ephemeral GC_SESSION_NAME=session-a \
    "$EMIT_JSON" --bead "$bead" --json-file "$TMP/a.json" --schema "$schema" --outcome pass) >"$TMP/a.out" 2>&1 & p1=$!
  (cd "$TMP/work-a"; GC_TRIGGER_BEAD_ID="$bead" GC_SESSION_ORIGIN=ephemeral GC_SESSION_NAME=session-b \
    "$EMIT_JSON" --bead "$bead" --json-file "$TMP/b.json" --schema "$schema" --outcome pass) >"$TMP/b.out" 2>&1 & p2=$!
  wait "$p1"; r1=$?; wait "$p2"; r2=$?
  set -e
  [ $(( (r1 == 0) + (r2 == 0) )) -eq 1 ] || fail "$schema race had success codes $r1/$r2"
  jq -e '.["gc.output_json"] | fromjson | .writer == "a" or .writer == "b"' "$TMP/state/$bead.json" >/dev/null \
    || fail "$schema race stored invalid output"
}

# Both bug and feature paths share emit-json; exercise each schema under contention.
run_json_race hard-bug-diagnosis.v1 bug-step
run_json_race feature-dev.v2 feature-step

# A stale caller-supplied bead cannot substitute for the trigger and performs no write.
printf '%s\n' '{}' >"$TMP/state/wrong-step.json"
: >"$TMP/gc.log"
if (cd "$TMP/work-a"; GC_TRIGGER_BEAD_ID=feature-step GC_SESSION_ORIGIN=ephemeral \
    "$EMIT_JSON" --bead wrong-step --json-file "$TMP/a.json" --schema feature-dev.v2 --outcome pass \
    >/dev/null 2>&1); then
  fail 'output emitter accepted a non-trigger bead'
fi
[ ! -s "$TMP/gc.log" ] || fail 'non-trigger output attempt caused a mutation'

# Review has a separate Python/schema path ending in emit-verdict; it receives the
# same lock/fence and must likewise produce exactly one durable winner.
printf '%s\n' '{}' >"$TMP/state/review-step.json"
review_payload() {
  jq -cn --arg writer "$1" '{schema:"pr-review.v1",head_ref:"",base_ref:"main",
    implementation_provenance:null,verdict:"approve",posture:"trusted",effective_posture:"trusted",
    ceiling_posture:"trusted",summary:$writer,merge_recommendation:"merge",findings_count:0,
    findings:[],dynamic_check:null,dynamic_request:null,evidence:[],
    read_only_enforcement:{clean:true,mutations_delta:[]},failure_class:"none",failure_reason:""}'
}
set +e
(cd "$TMP/work-a"; review_payload a | GC_TRIGGER_BEAD_ID=review-step GC_SESSION_ORIGIN=ephemeral GC_SESSION_NAME=session-a \
  python3 "$EMIT_REVIEW" --bead review-step --schema pr-review.v1 --outcome pass) >"$TMP/review-a.out" 2>&1 & p1=$!
(cd "$TMP/work-a"; review_payload b | GC_TRIGGER_BEAD_ID=review-step GC_SESSION_ORIGIN=ephemeral GC_SESSION_NAME=session-b \
  python3 "$EMIT_REVIEW" --bead review-step --schema pr-review.v1 --outcome pass) >"$TMP/review-b.out" 2>&1 & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
set -e
[ $(( (r1 == 0) + (r2 == 0) )) -eq 1 ] || fail "review race had success codes $r1/$r2"
jq -e '.["gc.output_json"] | fromjson | .summary == "a" or .summary == "b"' "$TMP/state/review-step.json" >/dev/null \
  || fail 'review race stored invalid output'

# Every pooled prompt family must invoke the shared gate before gc prime.
for prompt in \
  dev-pack/assets/prompts/bug-worker.prompt.template.md \
  dev-pack/assets/prompts/feature-dev.prompt.template.md \
  dev-pack/agents/bug-coordinator/prompt.template.md \
  dev-pack/agents/pr-triage/prompt.template.md \
  dev-pack/agents/pr-review-synthesizer/prompt.template.md \
  dev-pack/agents/pr-runner/prompt.template.md \
  dev-pack/agents/pr-follow-up/prompt.template.md; do
  grep -q '{{template "trigger-claim" .}}' "$ROOT/$prompt" || fail "$prompt omits trigger gate"
done
while IFS= read -r agent; do
  grep -q 'claim-trigger.sh' "$agent" || fail "$agent nudge can bypass trigger gate"
done < <(find "$ROOT/dev-pack/agents" -name agent.toml ! -path '*/pr-chat/*' -print)

printf 'trigger-bound pooled dispatch concurrency: ok\n'
