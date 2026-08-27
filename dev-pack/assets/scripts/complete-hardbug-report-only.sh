#!/usr/bin/env bash
# Persist and close the report-only terminal transition as one idempotent action.
set -euo pipefail

GC="${GC_BIN:-gc}"
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ARC="" ; STEP="" ; VERDICT="" ; STATE="" ; SUBJECT="" ; NOTIFY="${GC_HARDBUG_NOTIFY_TO:-human}"
cleanup_inputs() {
    local rc=0
    if [ -n "$STATE" ] && [ -e "$STATE" ]; then unlink "$STATE" || rc=$?; fi
    if [ -n "$VERDICT" ] && [ -e "$VERDICT" ]; then unlink "$VERDICT" || rc=$?; fi
    return "$rc"
}
trap cleanup_inputs EXIT
die() { printf 'complete-hardbug-report-only: %s\n' "$*" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --arc) ARC="${2:?}"; shift 2 ;;
        --step) STEP="${2:?}"; shift 2 ;;
        --verdict-file) VERDICT="${2:?}"; shift 2 ;;
        --state-file) STATE="${2:?}"; shift 2 ;;
        --subject) SUBJECT="${2:?}"; shift 2 ;;
        --notify) NOTIFY="${2:?}"; shift 2 ;;
        *) die "unknown argument '$1'" ;;
    esac
done
[ -n "$ARC" ] && [ -n "$STEP" ] && [ -f "$VERDICT" ] && [ -f "$STATE" ] \
    || die "--arc, --step, --verdict-file, and --state-file are required"
jq -e --arg arc "$ARC" '
  .next_action == "report_only" and .subject == $arc and
  (.failure_class // "none") == "none"' "$VERDICT" >/dev/null \
  || die "verdict is not a successful report_only transition for '$ARC'"
state=$(jq -ce --arg arc "$ARC" '
  if .bug_bead != $arc then error("state bug_bead mismatch") else .status="report_only" end' "$STATE")
arc_show=$("$GC" bd show "$ARC" --json) || die "cannot read arc '$ARC'"
[ "$(printf '%s' "$arc_show" | jq -r '.[0].status')" = open ] \
  || die "report-only investigation arc must remain open for human follow-up"
"$GC" bd update "$ARC" --set-metadata "gc.output_json=$state"
stored=$("$GC" bd show "$ARC" --json) || die "cannot verify arc '$ARC'"
printf '%s' "$stored" | jq -e --argjson expected "$state" '
  .[0].status == "open" and
  (.[0].metadata["gc.output_json"] | fromjson) == $expected' >/dev/null \
  || die "arc did not persist terminal report_only state while remaining open"
unlink "$STATE"

args=(--bead "$STEP" --json-file "$VERDICT" --schema hard-bug-reconcile.v1
    --outcome pass --render "$DIR/render-hardbug.sh" --consume --quiesce)
[ -z "$NOTIFY" ] || args+=(--notify "$NOTIFY")
[ -z "$SUBJECT" ] || args+=(--subject "$SUBJECT")
exec bash "$DIR/emit-json.sh" "${args[@]}"
