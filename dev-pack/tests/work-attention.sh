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
  ([.groups[] | select(.key == "in-flight") | .items[].id] | index("wo-flight") != null) and
  ([.groups[] | select(.key == "waiting") | .items[].id] | index("wo-wait") != null) and
  ([.groups[] | select(.key == "waiting") | .items[].id] | index("vllm-review") != null) and
  ([.groups[] | select(.key == "stale-unclear") | .items[].id] | index("wo-unclear") != null) and
  ([.groups[] | select(.key == "recently-finished") | .items[].id] | index("wo-finished") != null) and
  ([.groups[].items[].id] | index("wo-marker") != null) and
  ([.groups[].items[].id] | index("wo-hidden-step") == null) and
  ([.groups[].items[].id] | index("wo-message") == null)
' <<<"$json" >/dev/null

rig_json=$(cd "$TMP/city/rigs/vllm" && DEV_PACK_WORK_NOW="$NOW" GC_RIG=vllm \
  "$ROOT/dev-pack/commands/work/run.sh" --json)
jq -e '.scope.mode == "rig" and .scope.rigs == ["vllm"] and
       ([.groups[].items[].id] | sort == ["vllm-needs", "vllm-recheck", "vllm-review"])' <<<"$rig_json" >/dev/null

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
