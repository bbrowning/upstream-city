#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ITERATE="$ROOT/dev-pack/commands/iterate/run.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/repo"
cat >"$TMP/bin/resolve" <<'RESOLVE'
#!/usr/bin/env bash
set -euo pipefail
artifact=""
while [ $# -gt 0 ]; do
  case "$1" in --artifact) artifact=$2; shift 2 ;; --artifact=*) artifact=${1#*=}; shift ;; *) shift ;; esac
done
jq -cer --arg id "$artifact" '.items[] | select(.id==$id) | .metadata["gc.output_json"] | fromjson | .local_change' "$MOCK_STATE"
RESOLVE

cat >"$TMP/bin/gc" <<'GC'
#!/usr/bin/env bash
set -euo pipefail
while [ $# -gt 0 ]; do case "$1" in --city|--rig) shift 2 ;; *) break ;; esac; done
case "${1-} ${2-}" in
  "rig list") jq -cn --arg path "$MOCK_REPO" '{rigs:[{name:"fixture",path:$path}]}' ;;
  "agent list") printf '%s\n' fixture/feature-dev-frontier-high fixture/bug-worker-a-frontier-high fixture/bug-coordinator fixture/pr-reviewer-a-frontier-high fixture/pr-reviewer-b-frontier-high ;;
  "bd show") jq -ce --arg id "$3" '[.items[] | select(.id==$id)]' "$MOCK_STATE" ;;
  "bd list") jq -ce '.items' "$MOCK_STATE" ;;
  "bd create")
    shift 2; title=$1; shift; description=""; metadata='{}'; parent=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --description) description=$2; shift 2 ;; --metadata) metadata=$2; shift 2 ;;
        --parent) parent=$2; shift 2 ;; --type|--priority|--labels) shift 2 ;; --silent) shift ;;
        *) shift ;;
      esac
    done
    id=fixture-feedback
    jq --arg id "$id" --arg title "$title" --arg description "$description" --arg parent "$parent" \
      --argjson metadata "$metadata" '.items += [{id:$id,title:$title,description:$description,parent:$parent,status:"open",metadata:$metadata}]' \
      "$MOCK_STATE" >"$MOCK_STATE.next"; mv "$MOCK_STATE.next" "$MOCK_STATE"; printf '%s\n' "$id" ;;
  "bd close")
    id=$3; jq --arg id "$id" '(.items[]|select(.id==$id)|.status)="closed"' "$MOCK_STATE" >"$MOCK_STATE.next"; mv "$MOCK_STATE.next" "$MOCK_STATE" ;;
  "bd reopen")
    id=$3; jq --arg id "$id" '(.items[]|select(.id==$id)|.status)="open"' "$MOCK_STATE" >"$MOCK_STATE.next"; mv "$MOCK_STATE.next" "$MOCK_STATE" ;;
  "bd update")
    id=$3; shift 3
    cp "$MOCK_STATE" "$MOCK_STATE.next"
    while [ $# -gt 0 ]; do
      case "$1" in
        --set-metadata)
          pair=$2; key=${pair%%=*}; value=${pair#*=}
          jq --arg id "$id" --arg key "$key" --arg value "$value" '(.items[]|select(.id==$id)|.metadata[$key])=$value' \
            "$MOCK_STATE.next" >"$MOCK_STATE.tmp"; mv "$MOCK_STATE.tmp" "$MOCK_STATE.next"; shift 2 ;;
        --status)
          jq --arg id "$id" --arg value "$2" '(.items[]|select(.id==$id)|.status)=$value' \
            "$MOCK_STATE.next" >"$MOCK_STATE.tmp"; mv "$MOCK_STATE.tmp" "$MOCK_STATE.next"; shift 2 ;;
        *) shift ;;
      esac
    done
    mv "$MOCK_STATE.next" "$MOCK_STATE" ;;
  "sling "*)
    printf '%q ' "$@" >>"$MOCK_LOG"; printf '\n' >>"$MOCK_LOG"
    [ "${MOCK_SLING_FAIL:-0}" = 0 ] || { printf 'fixture dispatch failure\n' >&2; exit 1; }
    printf '%s\n' '{"root_bead_id":"fixture-workflow"}' ;;
  *) printf 'unexpected mock gc command: %s\n' "$*" >&2; exit 99 ;;
esac
GC
chmod +x "$TMP/bin/gc" "$TMP/bin/resolve"
cat >"$TMP/bin/editor" <<'EDITOR'
#!/usr/bin/env bash
printf '%s\n' 'Edited multiline feedback.' >"$1"
EDITOR
chmod +x "$TMP/bin/editor"
VISUAL="$TMP/bin/editor" python3 - "$ROOT/dev-pack/commands/iterate/run.py" <<'PY'
import argparse
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("iterate_run", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
class Terminal:
    def isatty(self): return True
sys.stdin = Terminal()
assert module.feedback_text(argparse.Namespace(feedback=None, file=None)) == "Edited multiline feedback.\n"
PY

artifact() { # intent workflow branch implementer
  local intent=$1 workflow=$2 branch=$3
  jq -cn --arg intent "$intent" --arg workflow "$workflow" --arg branch "$branch" '
    {schema:"local-change.v1",artifact_id:"artifact-r1",
     producer:{rig:"fixture",workflow:$workflow,bead:"fixture-work",intent_kind:$intent},
     repository:{id:"repo",git_common_dir:"/tmp/repo",object_format:"sha1"},
     base:{ref:"origin/main",sha:"1111111111111111111111111111111111111111"},
     head:{branch:$branch,sha:"2222222222222222222222222222222222222222"},
     revision:{number:1,lineage:{previous_artifact_id:null,producing_feedback:null}}}'
}

fixture() { # intent workflow branch implementer
  local intent=$1 workflow=$2 branch=$3 implementer=$4 local_change lifecycle
  local_change=$(artifact "$intent" "$workflow" "$branch")
  lifecycle=$(jq -cn --arg intent "$intent" '
    {schema:"work-lifecycle.v1",intent_kind:$intent,checkpoint:"review",disposition:"approved",
     iteration:1,artifact_id:"artifact-r1",head_sha:"2222222222222222222222222222222222222222",
     branch:"'"$branch"'",feedback_bead:"fixture-review",reason:"approve_with_nits"}')
  jq -cn --arg lifecycle "$lifecycle" --arg local "$local_change" --arg implementer "$implementer" '
    {items:[
      {id:"fixture-work",status:"closed",metadata:{"gc.lifecycle_json":$lifecycle}},
      {id:"fixture-impl",status:"closed",metadata:{"gc.kind":"retry","gc.output_json_schema":
       (if ($local|fromjson).producer.intent_kind=="feature" then "feature-dev.v2" else "hard-bug-implement.v2" end),
       "gc.execution_routed_to":$implementer,"gc.output_json":({local_change:($local|fromjson)}|tojson)}}
    ]}' >"$TMP/state.json"
  : >"$TMP/gc.log"
}

export GC_BIN="$TMP/bin/gc" GC_CITY_PATH="$TMP" DEV_PACK_RESOLVE_LOCAL_CHANGE="$TMP/bin/resolve"
export MOCK_STATE="$TMP/state.json" MOCK_LOG="$TMP/gc.log" MOCK_REPO="$TMP/repo"

fixture feature feature-dev paude/fixture-work fixture/feature-dev-frontier-high
out=$($ITERATE fixture-work 'Only update the requested documentation.' --max-review-iterations 3)
grep -Fq 'launched revision 2' <<<"$out" || fail 'feature receipt omitted revision'
jq -e '.items[] | select(.id=="fixture-work") |
  .status=="in_progress" and (.metadata["gc.lifecycle_json"]|fromjson|
  .checkpoint=="human_feedback" and .disposition=="implementing" and .iteration==2 and
  .predecessor.artifact_id=="artifact-r1") and
  (.metadata["gc.human_iteration_json"]|fromjson|.state=="launched" and .max_iteration==4)' \
  "$MOCK_STATE" >/dev/null || fail 'feature parent did not enter human-feedback lifecycle'
jq -e '.items[] | select(.id=="fixture-feedback") | .status=="closed" and
  (.metadata["gc.output_json"]|fromjson|.schema=="dev-pack-human-feedback.v1" and
  .feedback=="Only update the requested documentation." and .requested_revision==2 and
  .predecessor.artifact_id=="artifact-r1")' "$MOCK_STATE" >/dev/null \
  || fail 'durable human feedback record is incomplete'
for expected in 'feature-dev --formula' 'revision=2' 'previous_artifact_id=artifact-r1' \
  'feedback_bead=fixture-feedback' 'producing_verdict=request_changes' \
  'max_review_iterations=4' '--scope-kind rig' '--scope-ref fixture-feedback'; do
  grep -Fq -- "$expected" "$MOCK_LOG" || fail "feature sling lost $expected"
done
again=$($ITERATE fixture-work 'Only update the requested documentation.')
grep -Fq 'already running' <<<"$again" || fail 'repeat launch was not idempotent'
[ "$(wc -l <"$MOCK_LOG")" -eq 1 ] || fail 'repeat launch dispatched a duplicate workflow'

fixture hard_bug hard-bug-finalize fixes/fixture-work fixture/bug-worker-a-frontier-high
if printf '%s' 'Add a focused regression test.' | MOCK_SLING_FAIL=1 $ITERATE fixture-work --file - >"$TMP/fail.out" 2>"$TMP/fail.err"; then
  fail 'dispatch failure unexpectedly succeeded'
fi
grep -Fq 'iteration is prepared but dispatch failed' "$TMP/fail.err" || fail 'dispatch failure lacked recovery guidance'
jq -e '.items[] | select(.id=="fixture-work") | .status=="in_progress" and
  (.metadata["gc.human_iteration_json"]|fromjson|.state=="prepared")' "$MOCK_STATE" >/dev/null \
  || fail 'failed dispatch did not retain resumable state'
$ITERATE fixture-work 'Add a focused regression test.' >"$TMP/resume.out"
for expected in 'hard-bug-finalize --formula' 'branch_prefix=fixes/' \
  'coordinator_target=fixture/bug-coordinator'; do
  grep -Fq -- "$expected" "$MOCK_LOG" || fail "hard-bug sling lost $expected"
done
jq -e '.items[] | select(.id=="fixture-work") |
  (.metadata["gc.human_iteration_json"]|fromjson|.state=="launched")' "$MOCK_STATE" >/dev/null \
  || fail 'resumed dispatch was not marked launched'

fixture feature feature-dev paude/fixture-work fixture/feature-dev-frontier-high
dry=$($ITERATE fixture-work 'Preview this change.' --dry-run)
grep -Fq 'DRY RUN' <<<"$dry" || fail 'dry-run receipt missing'
jq -e '.items|length==2 and .[0].status=="closed"' "$MOCK_STATE" >/dev/null || fail 'dry-run mutated ledger'
piped=$(printf '%s' 'Piped preview.' | $ITERATE fixture-work --dry-run)
grep -Fq 'DRY RUN' <<<"$piped" || fail 'implicit piped feedback was not accepted'
if $ITERATE fixture-work 'Preview this change.' --max-review-iterations 0 --dry-run >/dev/null 2>"$TMP/zero.err"; then
  fail 'zero revision budget was accepted'
fi
grep -Fq 'must be a positive integer' "$TMP/zero.err" || fail 'zero revision budget error was unclear'

printf '%s\n' 'ok: dev-pack human feedback iteration'
