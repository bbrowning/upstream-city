#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d -p /var/tmp)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/city/rigs/vllm" "$TMP/bin"

cat >"$TMP/bin/gc" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${WORK_FIXTURE:?}"
printf '%s\n' "$*" >>"$WORK_FIXTURE/calls"
case " $* " in
  *" rig list --json "*) cat "$WORK_FIXTURE/rigs.json" ;;
  *" bd --readonly list "*)
    if [[ " $* " == *" --rig vllm "* ]]; then
      cat "$WORK_FIXTURE/vllm.json"
    else
      cat "$WORK_FIXTURE/hq.json"
    fi
    ;;
  *" bd --readonly show "*)
    id=${*: -2:1}
    if [[ " $* " == *" --rig vllm "* ]]; then file="$WORK_FIXTURE/vllm.json"; else file="$WORK_FIXTURE/hq.json"; fi
    jq --arg id "$id" '[.[] | select(.id == $id or .external_ref == $id)]' "$file"
    ;;
  *) printf 'unexpected gc invocation: %s\n' "$*" >&2; exit 90 ;;
esac
STUB
chmod +x "$TMP/bin/gc"

cat >"$TMP/rigs.json" <<JSON
{"ok":true,"rigs":[
  {"name":"city","path":"$TMP/city","prefix":"wo","hq":true,"beads":"initialized"},
  {"name":"vllm","path":"$TMP/city/rigs/vllm","prefix":"vllm","hq":false,"beads":"initialized"}
]}
JSON

cat >"$TMP/hq.json" <<'JSON'
[
 {"id":"wo-action","title":"Review completed implementation","status":"open","priority":1,"issue_type":"feature","owner":"human@example.com","created_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-31T22:00:00Z","metadata":{"gc.output_json":"{\"schema_version\":\"pr-review.v1\",\"verdict\":\"approve\"}"},"labels":[]},
 {"id":"wo-flight","title":"Implementation running","status":"in_progress","priority":1,"issue_type":"feature","assignee":"human@example.com","created_at":"2026-08-30T00:00:00Z","updated_at":"2026-08-31T22:30:00Z","labels":[]},
 {"id":"wo-wait","title":"Dependency-bound work","status":"blocked","priority":2,"issue_type":"task","owner":"human@example.com","created_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-29T00:00:00Z","labels":["wait:dependency"]},
 {"id":"wo-unclear","title":"Unstarted work","status":"open","priority":2,"issue_type":"task","owner":"human@example.com","created_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-20T00:00:00Z","labels":[]},
 {"id":"wo-finished","title":"Recently completed work","status":"closed","priority":2,"issue_type":"task","owner":"human@example.com","created_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-31T20:00:00Z","closed_at":"2026-08-31T20:00:00Z","labels":[]},
 {"id":"wo-marker","title":"Intentionally visible","status":"open","priority":3,"issue_type":"task","owner":"automation","created_at":"2026-08-31T00:00:00Z","updated_at":"2026-08-31T00:00:00Z","labels":["human-facing"]},
 {"id":"wo-hidden-step","title":"retry implementation","status":"in_progress","priority":1,"issue_type":"task","owner":"human@example.com","parent":"wo-flight","created_at":"2026-08-31T00:00:00Z","updated_at":"2026-08-31T22:45:00Z","labels":["gc:step"]},
 {"id":"wo-message","title":"workflow result","status":"open","priority":1,"issue_type":"message","owner":"human@example.com","created_at":"2026-08-31T00:00:00Z","updated_at":"2026-08-31T22:45:00Z","labels":[]}
]
JSON

cat >"$TMP/vllm.json" <<'JSON'
[
 {"id":"vllm-review","external_ref":"gh-42","title":"Maintainer review","status":"blocked","priority":1,"issue_type":"task","owner":"human@example.com","parent":"vllm-backlog","created_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-31T21:00:00Z","labels":["maintainer","wait:author"]}
 ,{"id":"vllm-needs","external_ref":"gh-99","title":"Consume completed review","status":"open","priority":1,"issue_type":"task","owner":"human@example.com","created_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-31T21:00:00Z","labels":["maintainer"]}
 ,{"id":"vllm-review-output","title":"review synthesis","status":"closed","priority":1,"issue_type":"task","owner":"automation","created_at":"2026-08-31T20:00:00Z","updated_at":"2026-08-31T22:00:00Z","metadata":{"gc.step_id":"synthesize","gc.output_json_schema":"pr-review-quorum.v1","gc.output_json":"{\"schema\":\"pr-review-quorum.v1\",\"head_ref\":\"99\",\"verdict\":\"approve\"}"},"labels":[]}
 ,{"id":"vllm-recheck","external_ref":"gh-100","title":"Waiting disposition superseded by new review","status":"blocked","priority":1,"issue_type":"task","owner":"human@example.com","created_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-31T21:00:00Z","labels":["maintainer","wait:author"]}
 ,{"id":"vllm-recheck-output","title":"new review synthesis","status":"closed","priority":1,"issue_type":"task","owner":"automation","created_at":"2026-08-31T21:30:00Z","updated_at":"2026-08-31T22:00:00Z","closed_at":"2026-08-31T22:00:00Z","metadata":{"gc.step_id":"synthesize","gc.human_source_bead":"vllm-recheck","gc.output_json_schema":"pr-review-quorum.v1","gc.output_json":"{\"schema\":\"pr-review-quorum.v1\",\"head_ref\":\"100\",\"verdict\":\"request_changes\"}"},"labels":[]}
 ,{"id":"vllm-adopt-source","external_ref":"gh-51517","title":"Publish adopted PR continuation","status":"open","priority":1,"issue_type":"task","owner":"human@example.com","created_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-31T20:00:00Z","labels":["maintainer"]}
 ,{"id":"vllm-adopt-old","title":"stale adoption attempt","status":"in_progress","priority":2,"issue_type":"task","owner":"automation","parent":"vllm-adopt-source","created_at":"2026-08-31T20:30:00Z","updated_at":"2026-08-31T21:00:00Z","labels":["internal"]}
 ,{"id":"vllm-adopt-result","title":"approved PR continuation","status":"closed","priority":2,"issue_type":"task","owner":"human@example.com","created_at":"2026-08-31T21:15:00Z","updated_at":"2026-08-31T22:30:00Z","closed_at":"2026-08-31T22:30:00Z","metadata":{"gc.human_source_bead":"vllm-adopt-source","gc.workflow":"pr-adopt.v1","gc.lifecycle_json":"{\"schema\":\"work-lifecycle.v1\",\"intent_kind\":\"pr_adopt\",\"checkpoint\":\"review\",\"disposition\":\"approved\",\"iteration\":1,\"artifact_id\":\"artifact-51517\",\"head_sha\":\"result51517\",\"branch\":\"adopt/pr-51517/vllm-adopt-result\",\"updated_at\":\"2026-08-31T22:30:00Z\"}","gc.pr_adoption_json":"{\"schema\":\"pr-adoption-input.v1\",\"source_pr\":51517,\"source_url\":\"https://github.com/vllm-project/vllm/pull/51517\",\"original_author\":\"Contributor\",\"contributor\":{\"repository\":\"Contributor/vllm\",\"branch\":\"feature\"},\"source_head_sha\":\"source51517\",\"target\":{\"ref\":\"main\",\"sha\":\"base51517\"},\"worktree\":\"/tmp/adopt-51517\",\"branch\":\"adopt/pr-51517/vllm-adopt-result\",\"strategy\":\"merge\",\"human_disposition_bead\":\"vllm-adopt-source\",\"recommended_upstream_action\":\"undecided\"}"},"labels":["internal","pr-adoption"]}
 ,{"id":"vllm-invalid-source","external_ref":"gh-51518","title":"Invalid adopted PR continuation","status":"open","priority":1,"issue_type":"task","owner":"human@example.com","created_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-31T20:00:00Z","labels":["maintainer"]}
 ,{"id":"vllm-invalid-result","title":"invalidated PR continuation","status":"closed","priority":2,"issue_type":"task","owner":"human@example.com","created_at":"2026-08-31T21:15:00Z","updated_at":"2026-08-31T22:40:00Z","closed_at":"2026-08-31T22:40:00Z","metadata":{"gc.human_source_bead":"vllm-invalid-source","gc.workflow":"pr-adopt.v1","gc.lifecycle_json":"{\"schema\":\"work-lifecycle.v1\",\"intent_kind\":\"pr_adopt\",\"checkpoint\":\"review\",\"disposition\":\"approved\",\"iteration\":1,\"artifact_id\":\"invalid-artifact\",\"head_sha\":\"invalid-result\",\"branch\":\"adopt/pr-51518/invalid\"}","gc.pr_adoption_json":"{\"schema\":\"pr-adoption-input.v1\",\"source_pr\":51518,\"source_head_sha\":\"source51518\",\"target\":{\"ref\":\"main\",\"sha\":\"stale-base\"},\"worktree\":\"/tmp/adopt-51518\",\"branch\":\"adopt/pr-51518/invalid\",\"strategy\":\"merge\"}","gc.pr_adoption_invalidation_json":"{\"schema\":\"pr-adoption-invalidation.v1\",\"status\":\"invalidated\",\"reason\":\"stale target pin\"}"},"labels":["internal","pr-adoption"]}
]
JSON

export GC_BIN="$TMP/bin/gc" GC_CITY_PATH="$TMP/city" WORK_FIXTURE="$TMP"
export GC_ATTENTION_ACTORS="human@example.com"
NOW=2026-08-31T23:00:00Z

json=$(DEV_PACK_WORK_NOW="$NOW" "$ROOT/dev-pack/commands/work/run.sh" --citywide --json)
jq -e '
  .schema_version == "dev-pack-work.v1" and
  ([.groups[] | select(.key == "needs-you") | .items[].id] | index("wo-action") != null) and
  ([.groups[] | select(.key == "needs-you") | .items[].id] | index("vllm-needs") != null) and
  ([.groups[] | select(.key == "needs-you") | .items[].id] | index("vllm-recheck") != null) and
  ([.groups[] | select(.key == "needs-you") | .items[].id] | index("vllm-adopt-source") != null) and
  ([.groups[] | select(.key == "in-flight") | .items[].id] | index("wo-flight") != null) and
  ([.groups[] | select(.key == "waiting") | .items[].id] | index("wo-wait") != null) and
  ([.groups[] | select(.key == "waiting") | .items[].id] | index("vllm-review") != null) and
  ([.groups[] | select(.key == "stale-unclear") | .items[].id] | index("wo-unclear") != null) and
  ([.groups[] | select(.key == "recently-finished") | .items[].id] | index("wo-finished") != null) and
  ([.groups[].items[].id] | index("wo-marker") != null) and
  ([.groups[].items[].id] | index("wo-hidden-step") == null) and
  ([.groups[].items[].id] | index("wo-message") == null) and
  ([.groups[].items[].id] | index("vllm-adopt-result") == null)
' <<<"$json" >/dev/null

rig_json=$(cd "$TMP/city/rigs/vllm" && DEV_PACK_WORK_NOW="$NOW" GC_RIG=vllm \
  "$ROOT/dev-pack/commands/work/run.sh" --json)
jq -e '.scope.mode == "rig" and .scope.rigs == ["vllm"] and
       ([.groups[].items[].id] | sort == ["vllm-adopt-source", "vllm-invalid-source", "vllm-needs", "vllm-recheck", "vllm-review"])' <<<"$rig_json" >/dev/null

adoption=$(DEV_PACK_WORK_NOW="$NOW" "$ROOT/dev-pack/commands/work/run.sh" show \
  vllm-adopt-source --rig vllm --no-network --json)
jq -e '
  .item.group == "needs-you" and
  (.item.reason | contains("local PR continuation approved")) and
  .item.active_workflow_children == [] and
  .item.superseded_active_workflow_children == ["vllm-adopt-old"] and
  .item.adoption_handoff.branch == "adopt/pr-51517/vllm-adopt-result" and
  .item.adoption_handoff.head_sha == "result51517" and
  .item.adoption_handoff.artifact_id == "artifact-51517" and
  .item.adoption_handoff.recommended_upstream_action == "undecided"
' <<<"$adoption" >/dev/null

adoption_text=$(DEV_PACK_WORK_NOW="$NOW" "$ROOT/dev-pack/commands/work/run.sh" show \
  vllm-adopt-source --rig vllm --no-network)
grep -Fq 'APPROVED LOCAL PR CONTINUATION' <<<"$adoption_text"
grep -Fq 'UPDATE ORIGINAL' <<<"$adoption_text"
grep -Fq 'REQUEST AUTHOR APPLY' <<<"$adoption_text"
grep -Fq 'SUPERSEDE' <<<"$adoption_text"
grep -Fq 'permission/consent' <<<"$adoption_text"
grep -Fq 'Nothing below has been pushed or published' <<<"$adoption_text"
grep -Fq 'YOUR_FORK_REMOTE' <<<"$adoption_text"

invalid=$(DEV_PACK_WORK_NOW="$NOW" "$ROOT/dev-pack/commands/work/run.sh" show \
  vllm-invalid-source --rig vllm --no-network --json)
jq -e '
  .item.group == "needs-you" and
  (.item.reason | contains("explicitly invalidated")) and
  .item.adoption_handoff.publication_status == "invalidated" and
  .item.adoption_handoff.invalidation.reason == "stale target pin" and
  .item.adoption_handoff.choices == {}
' <<<"$invalid" >/dev/null
invalid_text=$(DEV_PACK_WORK_NOW="$NOW" "$ROOT/dev-pack/commands/work/run.sh" show \
  vllm-invalid-source --rig vllm --no-network)
grep -Fq 'INVALIDATED LOCAL PR CONTINUATION — DO NOT PUBLISH' <<<"$invalid_text"
! grep -Fq 'UPDATE ORIGINAL' <<<"$invalid_text"
! grep -Fq 'YOUR_FORK_REMOTE' <<<"$invalid_text"
! grep -Fq 'gh pr create' <<<"$invalid_text"

show=$(DEV_PACK_WORK_NOW="$NOW" "$ROOT/dev-pack/commands/work/run.sh" show gh-42 --citywide --json)
jq -e '.item.id == "vllm-review" and .item.external_ref == "gh-42" and
       (.evidence.bead.status == "blocked")' <<<"$show" >/dev/null

group=$(DEV_PACK_WORK_NOW="$NOW" "$ROOT/dev-pack/commands/work/run.sh" --citywide \
  --group waiting --limit 1 --json)
jq -e '.groups | length == 1 and .[0].key == "waiting" and
       .[0].total == 2 and .[0].shown == 1' <<<"$group" >/dev/null

if DEV_PACK_WORK_NOW="$NOW" "$ROOT/dev-pack/commands/work/run.sh" --watch >"$TMP/watch.out" 2>&1; then
  echo "work --watch unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq 'explicitly deferred' "$TMP/watch.out"

grep -q 'bd --readonly list' "$TMP/calls"
! grep -Eq ' bd (update|close|set-state|create)| mail ' "$TMP/calls"

echo "work-attention: ok"
