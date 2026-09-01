#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/city/.gc" "$TMP/city/rigs/vllm" "$TMP/bin"
git -C "$TMP/city/rigs/vllm" init -q
git -C "$TMP/city/rigs/vllm" remote add origin git@github.com:example/project.git

cat > "$TMP/rigs.json" <<JSON
{"rigs":[{"name":"city","path":"$TMP/city","hq":true,"beads":"initialized"},{"name":"vllm","path":"$TMP/city/rigs/vllm","hq":false,"beads":"initialized"}]}
JSON
cat > "$TMP/hq.json" <<'JSON'
[]
JSON
cat > "$TMP/vllm.json" <<'JSON'
[
 {"id":"vllm-human-42","external_ref":"gh-42","title":"PR 42 disposition","status":"open","priority":1,"issue_type":"task","labels":["human-facing","attention"],"created_at":"2026-08-30T00:00:00Z","updated_at":"2026-08-31T00:00:00Z"},
 {"id":"vllm-out-42","title":"hidden result","status":"closed","issue_type":"task","closed_at":"2026-08-31T00:00:00Z","metadata":{"gc.step_id":"synthesis","gc.human_source_bead":"vllm-human-42","gc.reviewed_head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","gc.output_json_schema":"pr-review-quorum.v1","gc.output_json":"{\"schema\":\"pr-review-quorum.v1\",\"head_ref\":\"42\",\"verdict\":\"approve\"}"}},
 {"id":"vllm-human-43","external_ref":"gh-43","title":"legacy PR","status":"blocked","priority":1,"issue_type":"task","labels":["human-facing","wait:author"],"created_at":"2026-08-30T00:00:00Z","updated_at":"2026-08-31T00:00:00Z"},
 {"id":"vllm-out-43","title":"legacy result","status":"closed","issue_type":"task","metadata":{"gc.step_id":"review","gc.output_json_schema":"pr-review.v1","gc.output_json":"{\"schema\":\"pr-review.v1\",\"head_ref\":\"43\",\"verdict\":\"approve\"}"}},
 {"id":"vllm-human-44","external_ref":"gh-44","title":"merged PR","status":"open","priority":1,"issue_type":"task","labels":["human-facing"],"created_at":"2026-08-30T00:00:00Z","updated_at":"2026-08-31T00:00:00Z"},
 {"id":"vllm-out-44","title":"merged result","status":"closed","issue_type":"task","metadata":{"gc.step_id":"review","gc.human_source_bead":"vllm-human-44","gc.reviewed_head_sha":"cccccccccccccccccccccccccccccccccccccccc","gc.output_json_schema":"pr-review.v1","gc.output_json":"{\"schema\":\"pr-review.v1\",\"head_ref\":\"44\",\"verdict\":\"approve\"}"}},
 {"id":"vllm-mail","title":"PR review 42: approve","description":"PR 42 durable result available","status":"open","issue_type":"message","created_at":"2026-08-31T00:00:00Z","metadata":{"mail.from_display":"vllm/pr-review-synthesizer-1"}}
]
JSON

cat > "$TMP/bin/gc" <<'GC'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${RECON_CALLS:?}"
args=" $* "
if [[ "$args" == *" rig list --json "* ]]; then cat "$RECON_FIXTURE/rigs.json"
elif [[ "$args" == *" bd --readonly list "* ]]; then
  if [[ "$args" == *" --rig vllm "* ]]; then cat "$RECON_FIXTURE/vllm.json"; else cat "$RECON_FIXTURE/hq.json"; fi
elif [[ "$args" == *" bd --readonly show "* ]]; then
  target=${*: -2:1}; if [[ "$args" == *" --rig vllm "* ]]; then file="$RECON_FIXTURE/vllm.json"; else file="$RECON_FIXTURE/hq.json"; fi
  jq --arg target "$target" '[.[] | select(.id == $target or .external_ref == $target)]' "$file"
else printf 'unexpected gc call: %s\n' "$*" >&2; exit 99
fi
GC
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${RECON_GH_CALLS:?}"
number=$3
case "$number" in
  42) jq -cn '{state:"OPEN",headRefOid:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",reviewDecision:"CHANGES_REQUESTED",statusCheckRollup:[{conclusion:"SUCCESS"}],mergedAt:null,isDraft:false,updatedAt:"2026-09-01T00:00:00Z",url:"https://github.com/example/project/pull/42"}' ;;
  43) jq -cn '{state:"OPEN",headRefOid:"dddddddddddddddddddddddddddddddddddddddd",reviewDecision:"APPROVED",statusCheckRollup:[],mergedAt:null,isDraft:false,updatedAt:"2026-09-01T00:00:00Z",url:"https://github.com/example/project/pull/43"}' ;;
  44) jq -cn '{state:"MERGED",headRefOid:"cccccccccccccccccccccccccccccccccccccccc",reviewDecision:"APPROVED",statusCheckRollup:[{conclusion:"SUCCESS"}],mergedAt:"2026-09-01T00:00:00Z",isDraft:false,updatedAt:"2026-09-01T00:00:00Z",url:"https://github.com/example/project/pull/44"}' ;;
  *) exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gc" "$TMP/bin/gh"
export GC_BIN="$TMP/bin/gc" GH_BIN="$TMP/bin/gh" GC_CITY_PATH="$TMP/city"
export RECON_FIXTURE="$TMP" RECON_CALLS="$TMP/gc.calls" RECON_GH_CALLS="$TMP/gh.calls"
: > "$RECON_CALLS"; : > "$RECON_GH_CALLS"

json=$(DEV_PACK_WORK_NOW=2026-09-01T00:01:00Z "$ROOT/dev-pack/commands/work/run.sh" --citywide --refresh --json)
jq -e '
  ([.groups[] | select(.key=="needs-you") | .items[] | select(.id=="vllm-human-42")][0]) as $new |
  ([.groups[] | select(.key=="needs-you") | .items[] | select(.id=="vllm-human-43")][0]) as $legacy |
  ([.groups[] | select(.key=="needs-you") | .items[] | select(.id=="vllm-human-44")][0]) as $merged |
  $new.github.current_head_sha == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and
  $new.github.reviewed_head_sha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
  $new.github.changed_since_review == true and $new.github.ci_state == "passing" and
  ($new.retrieval.work_show | contains("work show vllm-human-42")) and
  ($new.retrieval.summary_or_status | any(contains("summary vllm-out-42"))) and
  $legacy.github.changed_since_review == null and ($legacy.reason | contains("does not record")) and
  ($merged.reason | contains("merged"))
' <<<"$json" >/dev/null
[ "$(wc -l < "$RECON_GH_CALLS")" -eq 3 ]

: > "$RECON_GH_CALLS"
offline=$(DEV_PACK_WORK_NOW=2026-09-02T00:01:00Z "$ROOT/dev-pack/commands/work/run.sh" --citywide --no-network --json)
[ ! -s "$RECON_GH_CALLS" ]
jq -e '[.groups[].items[] | select(.external_ref=="gh-42")][0].github.freshness == "stale-cache-no-network"' <<<"$offline" >/dev/null

audit=$(DEV_PACK_WORK_NOW=2026-09-01T00:02:00Z "$ROOT/dev-pack/commands/work/run.sh" audit --citywide --no-network --json)
jq -e '.outstanding_omissions == 0 and .checked.durable_review_outputs == 3 and .checked.human_mail_refs == 1 and .read_only == true' <<<"$audit" >/dev/null
! grep -Eq ' bd (update|create|close)| mail (read|mark-read)' "$RECON_CALLS"

printf '%s\n' '{"head_ref":"42","verdict":"approve","findings":[],"dynamic_check":null,"dynamic_request":"pytest -q"}' \
  | "$ROOT/dev-pack/assets/scripts/render-verdict.sh" - --brief \
  | grep -Fq 'suggested dynamic verification available'

echo 'work-github-reconciliation: ok'
