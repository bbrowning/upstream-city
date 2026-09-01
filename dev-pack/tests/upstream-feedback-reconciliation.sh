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
printf '[]\n' > "$TMP/hq.json"

jq -n '
  def source($n; $id): {id:$id, external_ref:("gh-"+$n), title:("Review PR "+$n), status:"open",
    priority:1, issue_type:"task", labels:["human-facing","blocked","needs-re-review"], created_at:"2026-08-30T00:00:00Z",
    updated_at:"2026-09-01T00:00:00Z", metadata:{}};
  def result($n; $id; $verdict; $sha; $time; $extra):
    {id:$id,title:("result "+$n),status:"closed",issue_type:"task",closed_at:$time,
     metadata:({"gc.output_json_schema":"pr-review-quorum.v1","gc.human_source_bead":("vllm-source-"+$n),
       "gc.output_json":({schema:"pr-review-quorum.v1",head_ref:$n,verdict:$verdict,
         summary:(if $id == "vllm-control-42" then "authoritative vllm-final-42" else ("authoritative "+$id) end),merge_recommendation:"Ready to merge.",
         findings:(if $verdict == "request_changes" then [{severity:"major",title:"Fix the edge case",file:"x.py",line:7,detail:"It fails for empty input.",suggested_fix:"Handle the empty input."}] else [] end),
         evidence:(if $sha == null then {} else {reviewed_head_sha:$sha} end)}|tojson)} + $extra)};
  [source("42";"vllm-source-42"),
   result("42";"vllm-old-42";"approve";"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";"2026-09-01T00:01:00Z";{}),
   result("42";"vllm-final-42";"request_changes";"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";"2026-09-01T00:03:00Z";{"gc.review_settle_role":"resynthesis"}),
   result("42";"vllm-control-42";"request_changes";"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";"2026-09-01T00:03:03Z";{"gc.kind":"retry","gc.review_settle_role":"resynthesis"}),
   source("43";"vllm-source-43"), result("43";"vllm-final-43";"approve";"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";"2026-09-01T00:03:00Z";{}),
   source("44";"vllm-source-44"), result("44";"vllm-final-44";"approve";"cccccccccccccccccccccccccccccccccccccccc";"2026-09-01T00:03:00Z";{}),
   source("45";"vllm-source-45"), result("45";"vllm-final-45";"approve";null;"2026-09-01T00:03:00Z";{}),
   source("46";"vllm-source-46"), result("46";"vllm-final-46";"approve";"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";"2026-09-01T00:03:00Z";{}),
   source("47";"vllm-source-47"), result("47";"vllm-final-47";"request_changes";"ffffffffffffffffffffffffffffffffffffffff";"2026-09-01T00:03:00Z";{}),
   source("48";"vllm-source-48"), result("48";"vllm-final-48";"approve";"9999999999999999999999999999999999999999";"2026-09-01T00:03:00Z";{})]
   + [source("49";"vllm-source-49"), result("49";"vllm-final-49";"request_changes";"1111111111111111111111111111111111111111";"2026-09-01T00:03:00Z";{}),
      source("50";"vllm-source-50"),
      source("51";"vllm-e5m8.2"), result("51";"vllm-old-51";"request_changes";"4b5d6bd800000000000000000000000000000000";"2026-09-01T00:03:00Z";{}),
      source("52";"vllm-source-52"), source("53";"vllm-source-53"),
      source("54";"vllm-source-54"), source("55";"vllm-source-55")]
' > "$TMP/vllm.json"

cat > "$TMP/bin/gc" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys
args=sys.argv[1:]
root=pathlib.Path(os.environ["HANDOFF_FIXTURE"])
with (root/"gc.calls").open("a") as stream: stream.write(" ".join(args)+"\n")
if "rig" in args and "list" in args:
    print((root/"rigs.json").read_text(), end=""); raise SystemExit
rig="vllm" if "--rig" in args and args[args.index("--rig")+1] == "vllm" else "hq"
path=root/(rig+".json")
data=json.loads(path.read_text())
if "bd" not in args: raise SystemExit(90)
op=args[args.index("bd")+1]
if op == "--readonly": op=args[args.index("bd")+2]
if op == "list": print(json.dumps(data)); raise SystemExit
if op == "show":
    target=args[args.index("show")+1]
    print(json.dumps([b for b in data if b.get("id") == target or b.get("external_ref") == target])); raise SystemExit
if op == "update":
    target=args[args.index("update")+1]; bead=next(b for b in data if b["id"] == target)
    bead.setdefault("metadata", {})
    for i,arg in enumerate(args):
        if arg == "--set-metadata":
            key,value=args[i+1].split("=",1); bead["metadata"][key]=value
        elif arg == "--unset-metadata": bead["metadata"].pop(args[i+1],None)
        elif arg == "--status": bead["status"]=args[i+1]
        elif arg == "--add-label" and args[i+1] not in bead["labels"]: bead["labels"].append(args[i+1])
        elif arg == "--remove-label" and args[i+1] in bead["labels"]: bead["labels"].remove(args[i+1])
        elif arg == "--append-notes": bead["notes"]=(bead.get("notes","")+"\n"+args[i+1]).strip()
    path.write_text(json.dumps(data)+"\n"); print(json.dumps(bead)); raise SystemExit
if op == "close":
    target=args[args.index("close")+1]; bead=next(b for b in data if b["id"] == target)
    bead["status"]="closed"; bead["closed_at"]="2026-09-01T00:10:00Z"
    path.write_text(json.dumps(data)+"\n"); print(json.dumps(bead)); raise SystemExit
raise SystemExit(91)
PY

cat > "$TMP/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys
root=pathlib.Path(os.environ["HANDOFF_FIXTURE"])
with (root/"gh.calls").open("a") as stream: stream.write(" ".join(sys.argv[1:])+"\n")
number=sys.argv[3]
states=json.loads((root/"gh-states.json").read_text())
value=states.get(number)
if value is None: raise SystemExit(1)
print(json.dumps({"state":value.get("state","OPEN"),"headRefOid":value["head"],"reviewDecision":value["review"],
 "statusCheckRollup":value.get("checks",[]),"mergedAt":value.get("mergedAt"),"isDraft":False,"updatedAt":"2026-09-01T00:04:00Z",
 "url":f"https://github.com/example/project/pull/{number}"}))
PY
chmod +x "$TMP/bin/gc" "$TMP/bin/gh"

cat > "$TMP/gh-states.json" <<'JSON'
{"42":{"head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","review":"REVIEW_REQUIRED"},
 "43":{"head":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","review":"APPROVED"},
 "44":{"head":"dddddddddddddddddddddddddddddddddddddddd","review":"APPROVED"},
 "45":{"head":"5555555555555555555555555555555555555555","review":"APPROVED"},
 "46":null,
 "47":{"head":"ffffffffffffffffffffffffffffffffffffffff","review":"REVIEW_REQUIRED"},
 "48":{"head":"9999999999999999999999999999999999999999","review":"CHANGES_REQUESTED"},
 "49":{"head":"2222222222222222222222222222222222222222","review":"REVIEW_REQUIRED","checks":[{"state":"IN_PROGRESS"}]},
 "50":{"head":"5050505050505050505050505050505050505050","review":"REVIEW_REQUIRED","checks":[]},
 "51":{"head":"f0176d2200000000000000000000000000000000","review":"REVIEW_REQUIRED","checks":[{"conclusion":"SUCCESS"}]},
 "52":{"head":"5252525252525252525252525252525252525252","review":"REVIEW_REQUIRED","checks":[{"conclusion":"SUCCESS"}]},
 "53":{"head":"5353535353535353535353535353535353535353","review":"REVIEW_REQUIRED","checks":[{"conclusion":"SUCCESS"}]},
 "54":{"head":"5454545454545454545454545454545454545454","review":"REVIEW_REQUIRED","checks":[{"state":"IN_PROGRESS"}]},
 "55":{"head":"5555555555555555555555555555555555555555","review":"REVIEW_REQUIRED","checks":[{"conclusion":"SUCCESS"}]}}
JSON

export GC_BIN="$TMP/bin/gc" GH_BIN="$TMP/bin/gh" GC_CITY_PATH="$TMP/city" HANDOFF_FIXTURE="$TMP"
: > "$TMP/gc.calls"; : > "$TMP/gh.calls"

show=$(DEV_PACK_WORK_NOW=2026-09-01T00:05:00Z "$ROOT/dev-pack/commands/work/run.sh" show vllm-source-42 --rig vllm --refresh --json)
jq -e '.item.decision.state == "upstream-action-required" and
  .item.decision.result_bead == "vllm-final-42" and
  .item.decision.recommended_action == "request_changes" and
  .item.decision.reviewed_head_sha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
  (.item.decision.commands.full_review == "gc dev-pack summary vllm-final-42 --rig vllm --full") and
  (.item.decision.commands.render_feedback == "gc dev-pack feedback vllm/vllm-source-42") and
  (.item.decision.commands.reconcile_after_github == "gc dev-pack reconcile vllm/vllm-source-42")' <<< "$show" >/dev/null
text=$(DEV_PACK_WORK_NOW=2026-09-01T00:05:00Z "$ROOT/dev-pack/commands/work/run.sh" show vllm-source-42 --rig vllm --no-network)
grep -Fq 'NEXT UPSTREAM ACTION' <<< "$text"
grep -Fq 'https://github.com/example/project/pull/42' <<< "$text"
grep -Fq 'Full automated review:' <<< "$text"
grep -Fq 'gc dev-pack summary vllm-final-42 --rig vllm --full' <<< "$text"
grep -Fq 'GitHub-ready review text:' <<< "$text"
grep -Fq 'AFTER SUBMITTING' <<< "$text"

: > "$TMP/gh.calls"
body=$("$ROOT/dev-pack/commands/feedback/run.sh" vllm/vllm-source-42 --no-network)
grep -Fq 'Requesting changes after review of `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`' <<< "$body"
grep -Fq 'Fix the edge case' <<< "$body"
[ ! -s "$TMP/gh.calls" ]
cached=$(DEV_PACK_WORK_NOW=2026-09-01T00:05:10Z "$ROOT/dev-pack/commands/feedback/run.sh" vllm/vllm-source-42)
grep -Fq 'Fix the edge case' <<< "$cached"
[ ! -s "$TMP/gh.calls" ]
override=$("$ROOT/dev-pack/commands/feedback/run.sh" vllm/vllm-source-42 --action approve --no-network)
grep -Fq 'Approved after review' <<< "$override"
! grep -Fq 'Fix the edge case' <<< "$override"
if "$ROOT/dev-pack/commands/feedback/run.sh" vllm/vllm-source-42 --rig hq >/dev/null 2>&1; then
  echo 'qualified target conflict unexpectedly succeeded' >&2; exit 1
fi
! grep -Eq ' bd (update|close)| mail | api | pr review' "$TMP/gc.calls"

for target in vllm-source-44 vllm-source-45 vllm-source-46 vllm-source-47; do
  if "$ROOT/dev-pack/commands/reconcile/run.sh" "vllm/$target" >/dev/null 2>"$TMP/$target.err"; then
    echo "$target reconciliation unexpectedly succeeded" >&2; exit 1
  fi
done
grep -Fq 'head drift' "$TMP/vllm-source-44.err"
grep -Fq 'lacks the exact reviewed SHA' "$TMP/vllm-source-45.err"
grep -Fq 'live GitHub observation is required' "$TMP/vllm-source-46.err"
grep -Fq 'perform the GitHub action first' "$TMP/vllm-source-47.err"

jq '."42".review="CHANGES_REQUESTED"' "$TMP/gh-states.json" > "$TMP/gh-next.json"
mv "$TMP/gh-next.json" "$TMP/gh-states.json"
before=$(grep -c 'bd update vllm-source-42' "$TMP/gc.calls" || true)
request_json=$("$ROOT/dev-pack/commands/reconcile/run.sh" vllm/vllm-source-42 --json)
jq -e '.changed == true and .action == "request_changes"' <<< "$request_json" >/dev/null
jq -e '.[] | select(.id=="vllm-source-42") | .status=="blocked" and
  (.labels|index("wait:author") != null) and (.labels|index("blocked") == null) and
  (.labels|index("needs-re-review") == null) and .metadata["gc.upstream_review_action"]=="request_changes"' "$TMP/vllm.json" >/dev/null
again=$("$ROOT/dev-pack/commands/reconcile/run.sh" vllm/vllm-source-42 --json)
jq -e '.changed == false and (.message|startswith("already reconciled"))' <<< "$again" >/dev/null
after=$(grep -c 'bd update vllm-source-42' "$TMP/gc.calls" || true)
[ "$after" -eq $((before + 1)) ]

approve_json=$("$ROOT/dev-pack/commands/reconcile/run.sh" vllm/vllm-source-43 --json)
jq -e '.changed == true and .action == "approve"' <<< "$approve_json" >/dev/null
jq -e '.[] | select(.id=="vllm-source-43") | .status=="closed" and .metadata["gc.upstream_review_action"]=="approve"' "$TMP/vllm.json" >/dev/null

disagree=$("$ROOT/dev-pack/commands/reconcile/run.sh" vllm/vllm-source-48 --as request-changes --json)
jq -e '.changed == true and .action == "request_changes"' <<< "$disagree" >/dev/null

if "$ROOT/dev-pack/commands/plan/run.sh" vllm/vllm-source-49 --wait-for author --then approve >/dev/null 2>"$TMP/invalid-plan.err"; then
  echo 'invalid plan combination unexpectedly succeeded' >&2; exit 1
fi
grep -Fq 'valid choices: inspect, re-review' "$TMP/invalid-plan.err"
plan=$("$ROOT/dev-pack/commands/plan/run.sh" vllm/vllm-source-49 --wait-for ci --then approve \
  --note 'Coverage is optional; comment posted.' --json)
jq -e '.changed == true and .plan.head_sha == "2222222222222222222222222222222222222222"' <<< "$plan" >/dev/null
pending=$("$ROOT/dev-pack/commands/work/run.sh" show vllm-source-49 --rig vllm --no-network --json)
jq -e '.item.group == "waiting" and .item.human_plan.state == "waiting" and
  .item.human_plan.then == "approve" and .item.human_plan.note == "Coverage is optional; comment posted."' <<< "$pending" >/dev/null
pending_text=$("$ROOT/dev-pack/commands/work/run.sh" show vllm-source-49 --rig vllm --no-network)
grep -Fq 'HUMAN PLAN' <<< "$pending_text"
grep -Fq 'No human action is required' <<< "$pending_text"
grep -Fq 'gc dev-pack plan vllm/vllm-source-49 --cancel' <<< "$pending_text"
for transition in failing drift; do
  if [ "$transition" = failing ]; then
    jq '."49".checks=[{"conclusion":"FAILURE"}]' "$TMP/gh-states.json" > "$TMP/gh-next.json"
  else
    jq '."49".checks=[{"state":"IN_PROGRESS"}] | ."49".head="3333333333333333333333333333333333333333"' "$TMP/gh-states.json" > "$TMP/gh-next.json"
  fi
  mv "$TMP/gh-next.json" "$TMP/gh-states.json"
  changed=$("$ROOT/dev-pack/commands/work/run.sh" show vllm-source-49 --rig vllm --refresh --json)
  expected="ci-failing"; [ "$transition" = drift ] && expected="head-drift"
  jq -e --arg expected "$expected" '.item.group == "needs-you" and .item.human_plan.state == $expected' <<< "$changed" >/dev/null
  jq '."49".checks=[{"state":"IN_PROGRESS"}] | ."49".head="2222222222222222222222222222222222222222"' "$TMP/gh-states.json" > "$TMP/gh-next.json"
  mv "$TMP/gh-next.json" "$TMP/gh-states.json"
done
if "$ROOT/dev-pack/commands/reconcile/run.sh" vllm/vllm-source-49 --as approve >/dev/null 2>"$TMP/plan-pending.err"; then
  echo 'pending plan reconciliation unexpectedly succeeded' >&2; exit 1
fi
grep -Fq 'CI is still pending' "$TMP/plan-pending.err"
"$ROOT/dev-pack/commands/plan/run.sh" vllm/vllm-source-49 --cancel >/dev/null
jq -e '.[] | select(.id=="vllm-source-49") | .status=="open" and
  (.metadata["gc.human_plan_json"] == null) and (.labels|index("wait:ci") == null)' "$TMP/vllm.json" >/dev/null
"$ROOT/dev-pack/commands/plan/run.sh" vllm/vllm-source-49 --wait-for ci --then approve \
  --note 'Coverage is optional; comment posted.' >/dev/null
jq '."49".review="REVIEW_REQUIRED" | ."49".checks=[{"conclusion":"SUCCESS"}]' "$TMP/gh-states.json" > "$TMP/gh-next.json"
mv "$TMP/gh-next.json" "$TMP/gh-states.json"
ready=$("$ROOT/dev-pack/commands/work/run.sh" show vllm-source-49 --rig vllm --refresh --json)
jq -e '.item.group == "needs-you" and .item.human_plan.state == "ready" and
  .item.next_action == "Approve for the current exact head"' <<< "$ready" >/dev/null
if "$ROOT/dev-pack/commands/reconcile/run.sh" vllm/vllm-source-49 --as approve >/dev/null 2>"$TMP/plan-unsubmitted.err"; then
  echo 'unsubmitted planned approval unexpectedly reconciled' >&2; exit 1
fi
grep -Fq 'perform the GitHub action first' "$TMP/plan-unsubmitted.err"
jq '."49".review="APPROVED"' "$TMP/gh-states.json" > "$TMP/gh-next.json"
mv "$TMP/gh-next.json" "$TMP/gh-states.json"
planned_reconcile=$("$ROOT/dev-pack/commands/reconcile/run.sh" vllm/vllm-source-49 --as approve --json)
jq -e '.changed == true and .reviewed_head_sha == "2222222222222222222222222222222222222222"' <<< "$planned_reconcile" >/dev/null
jq -e '.[] | select(.id=="vllm-source-49") | .status=="closed" and
  .metadata["gc.human_plan_json"] == null and .metadata["gc.upstream_review_action"] == "approve"' "$TMP/vllm.json" >/dev/null

"$ROOT/dev-pack/commands/plan/run.sh" vllm/vllm-source-50 --wait-for author --then re-review >/dev/null
author_wait=$("$ROOT/dev-pack/commands/work/run.sh" show vllm-source-50 --rig vllm --no-network --json)
jq -e '.item.group == "waiting" and .item.human_plan.state == "waiting"' <<< "$author_wait" >/dev/null
jq '."50".head="5151515151515151515151515151515151515151"' "$TMP/gh-states.json" > "$TMP/gh-next.json"
mv "$TMP/gh-next.json" "$TMP/gh-states.json"
author_ready=$("$ROOT/dev-pack/commands/work/run.sh" show vllm-source-50 --rig vllm --refresh --json)
jq -e '.item.group == "needs-you" and .item.human_plan.state == "ready" and
  .item.next_action == "Re-review for the current exact head"' <<< "$author_ready" >/dev/null

# vllm-e5m8.2 incident: a passing exact-head plan was canceled before the human
# approved and merged; only an older automated review exists at a different SHA.
"$ROOT/dev-pack/commands/plan/run.sh" vllm/vllm-e5m8.2 --wait-for ci --then approve \
  --note 'Coverage expansion is optional; comment posted on GitHub.' >/dev/null
"$ROOT/dev-pack/commands/plan/run.sh" vllm/vllm-e5m8.2 --cancel >/dev/null
jq -e '.[] | select(.id=="vllm-e5m8.2") | .status=="open" and
  .metadata["gc.human_plan_json"] == null and
  (.metadata["gc.human_plan_archive_json"]|fromjson|.plans[-1].head_sha) == "f0176d2200000000000000000000000000000000" and
  (.metadata["gc.human_plan_archive_json"]|fromjson|.plans[-1].condition_satisfied) == true and
  (.metadata["gc.human_plan_archive_json"]|fromjson|.plans[-1].archived_outcome) == "canceled"' "$TMP/vllm.json" >/dev/null
jq '."51".review="APPROVED" | ."51".state="MERGED" | ."51".mergedAt="2026-09-01T00:06:00Z"' \
  "$TMP/gh-states.json" > "$TMP/gh-next.json"
mv "$TMP/gh-next.json" "$TMP/gh-states.json"
# A later aggregate check failure cannot erase that CI was satisfied when archived.
jq '."51".checks=[{"conclusion":"FAILURE"}]' "$TMP/gh-states.json" > "$TMP/gh-next.json"
mv "$TMP/gh-next.json" "$TMP/gh-states.json"
merged=$(DEV_PACK_WORK_NOW=2026-09-01T00:07:00Z "$ROOT/dev-pack/commands/work/run.sh" show vllm-e5m8.2 --rig vllm --refresh 2>&1)
grep -Fq 'UPSTREAM COMPLETION OBSERVED' <<< "$merged"
grep -Fq 'gc dev-pack reconcile vllm/vllm-e5m8.2 --as approve' <<< "$merged"
! grep -Fq 'REVIEW REQUIRED' <<< "$merged"
! grep -Fq 'head 4b5d6bd8' <<< "$merged"
incident=$("$ROOT/dev-pack/commands/reconcile/run.sh" vllm/vllm-e5m8.2 --json 2>&1)
jq -e '.changed == true and .action == "approve" and .reviewed_head_sha == "f0176d2200000000000000000000000000000000"' <<< "$incident" >/dev/null
jq -e '.[] | select(.id=="vllm-e5m8.2") | .status=="closed" and
  .metadata["gc.upstream_review_action"] == "approve" and
  .metadata["gc.human_plan_archive_json"] != null' "$TMP/vllm.json" >/dev/null
incident_again=$("$ROOT/dev-pack/commands/reconcile/run.sh" vllm/vllm-e5m8.2 --json)
jq -e '.changed == false and (.message|startswith("already reconciled"))' <<< "$incident_again" >/dev/null
finished=$(DEV_PACK_WORK_NOW=2026-09-01T00:08:00Z "$ROOT/dev-pack/commands/work/run.sh" show vllm-e5m8.2 --rig vllm --refresh 2>&1)
grep -Fq 'recently-finished · closed' <<< "$finished"
grep -Fq 'next: none; reopen only if the human disposition changes' <<< "$finished"
! grep -Fq 'REVIEW REQUIRED' <<< "$finished"
! grep -Fq 'head 4b5d6bd8' <<< "$finished"

# Cancellation cannot discard completion evidence once the live refresh sees it.
"$ROOT/dev-pack/commands/plan/run.sh" vllm/vllm-source-52 --wait-for ci --then approve >/dev/null
jq '."52".review="APPROVED"' "$TMP/gh-states.json" > "$TMP/gh-next.json"; mv "$TMP/gh-next.json" "$TMP/gh-states.json"
if "$ROOT/dev-pack/commands/plan/run.sh" vllm/vllm-source-52 --cancel >/dev/null 2>"$TMP/cancel-approved.err"; then
  echo 'cancel after observed approval unexpectedly succeeded' >&2; exit 1
fi
grep -Fq 'gc dev-pack reconcile vllm/vllm-source-52 --as approve' "$TMP/cancel-approved.err"
jq -e '.[] | select(.id=="vllm-source-52") | .metadata["gc.human_plan_json"] != null' "$TMP/vllm.json" >/dev/null

"$ROOT/dev-pack/commands/plan/run.sh" vllm/vllm-source-53 --wait-for ci --then approve >/dev/null
jq '."53".state="MERGED" | ."53".mergedAt="2026-09-01T00:06:00Z"' "$TMP/gh-states.json" > "$TMP/gh-next.json"; mv "$TMP/gh-next.json" "$TMP/gh-states.json"
if "$ROOT/dev-pack/commands/plan/run.sh" vllm/vllm-source-53 --cancel >/dev/null 2>"$TMP/cancel-merged.err"; then
  echo 'cancel after observed merge unexpectedly succeeded' >&2; exit 1
fi
grep -Fq 'gc dev-pack reconcile vllm/vllm-source-53 --as approve' "$TMP/cancel-merged.err"

# Archived evidence still enforces the original condition, exact head, and state.
"$ROOT/dev-pack/commands/plan/run.sh" vllm/vllm-source-54 --wait-for ci --then approve >/dev/null
"$ROOT/dev-pack/commands/plan/run.sh" vllm/vllm-source-54 --cancel >/dev/null
jq '."54".review="APPROVED"' "$TMP/gh-states.json" > "$TMP/gh-next.json"; mv "$TMP/gh-next.json" "$TMP/gh-states.json"
if "$ROOT/dev-pack/commands/reconcile/run.sh" vllm/vllm-source-54 --as approve >/dev/null 2>"$TMP/archive-pending.err"; then
  echo 'unsatisfied archived plan unexpectedly reconciled' >&2; exit 1
fi
grep -Fq 'CI is still pending' "$TMP/archive-pending.err"

"$ROOT/dev-pack/commands/plan/run.sh" vllm/vllm-source-55 --wait-for ci --then approve >/dev/null
"$ROOT/dev-pack/commands/plan/run.sh" vllm/vllm-source-55 --wait-for ci --then request-changes >/dev/null
jq -e '.[] | select(.id=="vllm-source-55") |
  (.metadata["gc.human_plan_archive_json"]|fromjson|.plans[-1].archived_outcome) == "replaced"' "$TMP/vllm.json" >/dev/null
"$ROOT/dev-pack/commands/plan/run.sh" vllm/vllm-source-55 --cancel >/dev/null
jq '."55".review="APPROVED" | ."55".head="5656565656565656565656565656565656565656"' "$TMP/gh-states.json" > "$TMP/gh-next.json"; mv "$TMP/gh-next.json" "$TMP/gh-states.json"
if "$ROOT/dev-pack/commands/reconcile/run.sh" vllm/vllm-source-55 --as approve >/dev/null 2>"$TMP/archive-drift.err"; then
  echo 'head-drifted archived plan unexpectedly reconciled' >&2; exit 1
fi
grep -Eq 'head drift|exact head has changed' "$TMP/archive-drift.err"

! grep -Eq ' mail | api | pr review' "$TMP/gc.calls"
! grep -Eq ' pr review| api | graphql ' "$TMP/gh.calls"

echo 'upstream-feedback-reconciliation: ok'
