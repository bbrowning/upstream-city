#!/usr/bin/env bash
# Lead-owned second-tier escalation for decisions outside a single rig's authority.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
RIG="" WORK_BEAD="" DECISION_KIND="" REASON=""
die() { printf '%s\n' "escalate-rig-work-to-mayor: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --rig) RIG="${2:?}"; shift 2 ;; --rig=*) RIG="${1#*=}"; shift ;;
    --work-bead) WORK_BEAD="${2:?}"; shift 2 ;; --work-bead=*) WORK_BEAD="${1#*=}"; shift ;;
    --decision-kind) DECISION_KIND="${2:?}"; shift 2 ;; --decision-kind=*) DECISION_KIND="${1#*=}"; shift ;;
    --reason) REASON="${2:?}"; shift 2 ;; --reason=*) REASON="${1#*=}"; shift ;;
    -*) die "unknown option '$1'" ;; *) die "unexpected argument '$1'" ;;
  esac
done
[ -n "$RIG" ] && [ -n "$WORK_BEAD" ] && [ -n "$REASON" ] || die "--rig, --work-bead, and --reason are required"
case "$DECISION_KIND" in human|cross_rig|resource|city_policy) ;; *) die "--decision-kind must be human, cross_rig, resource, or city_policy" ;; esac

gc_cmd=("$GC" --city "$CITY" --rig "$RIG")
raw=$("${gc_cmd[@]}" bd show "$WORK_BEAD" --json) || die "could not read $WORK_BEAD"
lead_escalation=$(printf '%s' "$raw" | jq -r '(if type == "array" then .[0] else . end).metadata["gc.lead_escalation_json"] // empty')
[ -n "$lead_escalation" ] && printf '%s' "$lead_escalation" | jq -e '.schema == "rig-lead-escalation.v1" and .notified == true' >/dev/null \
  || die "$WORK_BEAD has no completed rig-lead escalation"
key=$(printf '%s:%s:%s:%s' "$RIG" "$WORK_BEAD" "$DECISION_KIND" "$REASON" | sha256sum | awk '{print $1}')
existing=$(printf '%s' "$raw" | jq -r '(if type == "array" then .[0] else . end).metadata["gc.mayor_escalation_json"] // empty')
if [ -n "$existing" ] && printf '%s' "$existing" | jq -e --arg key "$key" '.key == $key and .notified == true' >/dev/null; then
  printf '%s\n' "$existing"; exit 0
fi

escalation=$(jq -cn --arg schema mayor-escalation.v1 --arg key "$key" --arg rig "$RIG" \
  --arg work "$WORK_BEAD" --arg kind "$DECISION_KIND" --arg reason "$REASON" --argjson lead_escalation "$lead_escalation" \
  '{schema:$schema,key:$key,rig:$rig,work_bead:$work,decision_kind:$kind,reason:$reason,
    lead_escalation:$lead_escalation,notified:false}')
"${gc_cmd[@]}" bd set-state "$WORK_BEAD" hold=mayor --reason "lead second-tier escalation ($DECISION_KIND): $REASON"
"${gc_cmd[@]}" bd update "$WORK_BEAD" --status in_progress --set-metadata "gc.mayor_escalation_json=$escalation"
"${gc_cmd[@]}" mail send mayor --notify --subject "MAYOR ESCALATION [$key]: $WORK_BEAD" \
  --message "Rig $RIG lead requests a $DECISION_KIND decision for $WORK_BEAD: $REASON. The complete first-tier evidence is stored in gc.lead_escalation_json." >/dev/null
escalation=$(printf '%s' "$escalation" | jq -c '.notified = true')
"${gc_cmd[@]}" bd update "$WORK_BEAD" --status in_progress --set-metadata "gc.mayor_escalation_json=$escalation"
printf '%s\n' "$escalation"
