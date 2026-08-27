#!/usr/bin/env bash
# Durably route bounded, rig-scoped workflow exhaustion to the owning rig lead.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
RIG="" WORK_BEAD="" WORKFLOW="" REASON="" PHASE="" ITERATION=""
BRANCH="" HEAD_SHA="" ARTIFACT_ID="" EVIDENCE_BEADS=""

die() { printf '%s\n' "escalate-rig-work: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --rig) RIG="${2:?}"; shift 2 ;; --rig=*) RIG="${1#*=}"; shift ;;
    --work-bead) WORK_BEAD="${2:?}"; shift 2 ;; --work-bead=*) WORK_BEAD="${1#*=}"; shift ;;
    --workflow) WORKFLOW="${2:?}"; shift 2 ;; --workflow=*) WORKFLOW="${1#*=}"; shift ;;
    --reason) REASON="${2:?}"; shift 2 ;; --reason=*) REASON="${1#*=}"; shift ;;
    --phase) PHASE="${2:?}"; shift 2 ;; --phase=*) PHASE="${1#*=}"; shift ;;
    --iteration) ITERATION="${2:?}"; shift 2 ;; --iteration=*) ITERATION="${1#*=}"; shift ;;
    --branch) BRANCH="${2-}"; shift 2 ;; --branch=*) BRANCH="${1#*=}"; shift ;;
    --head-sha) HEAD_SHA="${2-}"; shift 2 ;; --head-sha=*) HEAD_SHA="${1#*=}"; shift ;;
    --artifact-id) ARTIFACT_ID="${2-}"; shift 2 ;; --artifact-id=*) ARTIFACT_ID="${1#*=}"; shift ;;
    --evidence-beads) EVIDENCE_BEADS="${2-}"; shift 2 ;; --evidence-beads=*) EVIDENCE_BEADS="${1#*=}"; shift ;;
    -*) die "unknown option '$1'" ;; *) die "unexpected argument '$1'" ;;
  esac
done

for pair in "rig:$RIG" "work-bead:$WORK_BEAD" "workflow:$WORKFLOW" "reason:$REASON" \
  "phase:$PHASE" "iteration:$ITERATION"; do
  [ -n "${pair#*:}" ] || die "--${pair%%:*} is required"
done
case "$ITERATION" in *[!0-9]*|'') die "--iteration must be a non-negative integer" ;; esac
case "$RIG" in */*|*[!A-Za-z0-9._-]*) die "--rig must be a rig name, not a session target" ;; esac

evidence_json=$(printf '%s' "$EVIDENCE_BEADS" | jq -Rc \
  'split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0)) | unique')
key=$(jq -cn --arg rig "$RIG" --arg work "$WORK_BEAD" --arg workflow "$WORKFLOW" \
  --arg reason "$REASON" --arg phase "$PHASE" --argjson iteration "$ITERATION" \
  --arg branch "$BRANCH" --arg head "$HEAD_SHA" --arg artifact "$ARTIFACT_ID" \
  --argjson evidence "$evidence_json" \
  '{rig:$rig,work_bead:$work,workflow:$workflow,reason:$reason,phase:$phase,iteration:$iteration,
    branch:$branch,head_sha:$head,artifact_id:$artifact,evidence_beads:$evidence}' | sha256sum | awk '{print $1}')

gc_cmd=("$GC" --city "$CITY" --rig "$RIG")
raw=$("${gc_cmd[@]}" bd show "$WORK_BEAD" --json) || die "could not read $WORK_BEAD"
status=$(printf '%s' "$raw" | jq -er '(if type == "array" then .[0] else . end).status')
[ "$status" != closed ] || die "cannot escalate closed work bead $WORK_BEAD"
existing=$(printf '%s' "$raw" | jq -r '(if type == "array" then .[0] else . end).metadata["gc.lead_escalation_json"] // empty')
if [ -n "$existing" ] && printf '%s' "$existing" | jq -e --arg key "$key" \
  '.schema == "rig-lead-escalation.v1" and .key == $key and .notified == true' >/dev/null; then
  printf '%s\n' "$existing"
  exit 0
fi

created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
escalation=$(jq -cn --arg schema rig-lead-escalation.v1 --arg key "$key" --arg rig "$RIG" \
  --arg lead "$RIG/lead" --arg work "$WORK_BEAD" --arg workflow "$WORKFLOW" \
  --arg reason "$REASON" --arg phase "$PHASE" --argjson iteration "$ITERATION" \
  --arg branch "$BRANCH" --arg head "$HEAD_SHA" --arg artifact "$ARTIFACT_ID" \
  --argjson evidence "$evidence_json" --arg created "$created_at" \
  '{schema:$schema,key:$key,rig:$rig,lead:$lead,work_bead:$work,workflow:$workflow,
    reason:$reason,phase:$phase,iteration:$iteration,
    branch:(if $branch=="" then null else $branch end),head_sha:(if $head=="" then null else $head end),
    artifact_id:(if $artifact=="" then null else $artifact end),evidence_beads:$evidence,
    notified:false,created_at:$created}')
"${gc_cmd[@]}" bd update "$WORK_BEAD" --status in_progress --set-metadata "gc.lead_escalation_json=$escalation"

body=$(printf '%s' "$escalation" | jq -r '
  "Rig workflow exhausted; the parent remains open and has no mayor hold.\n" +
  "work: \(.work_bead)\nworkflow: \(.workflow)\nphase/iteration: \(.phase)/\(.iteration)\n" +
  "reason: \(.reason)\nbranch: \(.branch // "n/a")\nhead SHA: \(.head_sha // "n/a")\n" +
  "artifact: \(.artifact_id // "n/a")\nevidence beads: \(.evidence_beads | if length == 0 then "n/a" else join(", ") end)\n\n" +
  "Inspect the evidence and either re-scope, adjust bounded review/convergence settings, authorize a new bounded attempt, or use escalate-rig-work-to-mayor.sh for a genuinely human/cross-rig/resource/city-policy decision."')
"${gc_cmd[@]}" mail send "$RIG/lead" --notify --subject "LEAD ESCALATION [$key]: $WORK_BEAD" --message "$body" >/dev/null

escalation=$(printf '%s' "$escalation" | jq -c '.notified = true')
"${gc_cmd[@]}" bd update "$WORK_BEAD" --status in_progress --set-metadata "gc.lead_escalation_json=$escalation"
printf '%s\n' "$escalation"
