#!/usr/bin/env bash
# emit-verdict.sh — finish a review / dynamic-check step ATOMICALLY in ONE command:
# write output_json, set outcome, CLOSE the bead, and (unless disabled) NOTIFY the
# human. Closing and notifying are inseparable here, so a notification can never be
# a forgotten trailing step — completing the step IS notifying.
#
#   emit-verdict.sh --bead <id> --verdict-file <path.json> --outcome pass|fail \
#       [--failure-class none|transient|hard] [--failure-reason STR] [--reason CLOSE_MSG]
#
# Schema is auto-detected from the verdict JSON: `.verdict` present -> pr-review.v1
# (review); else -> pr-review-dynamic.v1 (dynamic check). Notification content is
# DERIVED from the verdict JSON, so the human always gets the actual results.
#
# NOTIFICATION IS OPERATOR POLICY, not the pack's: the mail goes to $GC_PR_NOTIFY_TO
# (default "human"). Set GC_PR_NOTIFY_TO="" (e.g. in a [[rigs.patches]] env block on
# the reviewer/runner agent) to disable the pack's built-in notify and handle it your
# own way. Dashboard base is $GC_DASHBOARD_BASE (default the local supervisor UI).
set -euo pipefail

GC="${GC_BIN:-gc}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEAD="" ; VF="" ; OUTCOME="pass" ; FCLASS="none" ; FREASON="" ; REASON=""

die() { printf '%s\n' "emit-verdict: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --bead)           BEAD="${2:?}"; shift 2 ;;
        --bead=*)         BEAD="${1#*=}"; shift ;;
        --verdict-file)   VF="${2:?}"; shift 2 ;;
        --verdict-file=*) VF="${1#*=}"; shift ;;
        --outcome)        OUTCOME="${2:?}"; shift 2 ;;
        --outcome=*)      OUTCOME="${1#*=}"; shift ;;
        --failure-class)  FCLASS="${2:?}"; shift 2 ;;
        --failure-class=*) FCLASS="${1#*=}"; shift ;;
        --failure-reason) FREASON="${2:?}"; shift 2 ;;
        --failure-reason=*) FREASON="${1#*=}"; shift ;;
        --reason)         REASON="${2:?}"; shift 2 ;;
        --reason=*)       REASON="${1#*=}"; shift ;;
        -*)               die "unknown option '$1'" ;;
        *)                die "unexpected argument '$1'" ;;
    esac
done

[ -n "$BEAD" ] || die "usage: --bead is required"
[ -n "$VF" ] && [ -f "$VF" ] || die "usage: --verdict-file must be an existing file"
OUT=$(jq -c . "$VF") || die "verdict file is not valid JSON: $VF"

# --- write metadata (MERGE — never --metadata '{…}', which wipes routing keys) ---
"$GC" bd update "$BEAD" --set-metadata "gc.output_json=$OUT" --set-metadata "gc.outcome=$OUTCOME"
if [ "$FCLASS" != "none" ]; then
    "$GC" bd update "$BEAD" --set-metadata "gc.failure_class=$FCLASS" --set-metadata "gc.failure_reason=$FREASON"
fi

# --- CLOSE the step ----------------------------------------------------------
if [ -z "$REASON" ]; then
    if jq -e '.verdict' "$VF" >/dev/null 2>&1; then
        REASON="review: $(jq -r '.verdict // "?"' "$VF") ($(jq -r '.findings_count // 0' "$VF") findings)"
    else
        REASON="dynamic check: $(jq -r '.outcome // "?"' "$VF")"
    fi
fi
"$GC" bd close "$BEAD" --reason "$REASON"

# --- NOTIFY (operator policy; default human, empty disables) ------------------
TO="${GC_PR_NOTIFY_TO-human}"
[ -z "$TO" ] && exit 0   # notification disabled by the operator

# One fetch of the bead's metadata, reused below for the run link.
bead_json=$("$GC" bd show "$BEAD" --json 2>/dev/null || true)

# A review-quorum LANE must never notify the human — the SYNTHESIS step mails the
# human exactly once for the whole quorum. Lane beads are stamped
# gc.review_quorum_lane by the formula; the synthesis bead is not (it carries
# gc.review_quorum_role=synthesis). This keys off metadata the formula already sets,
# so it needs no env/reload and can't be forgotten in a prompt.
qlane=$(printf '%s' "$bead_json" | jq -r '.[0].metadata["gc.review_quorum_lane"] // empty' 2>/dev/null || true)
[ -n "$qlane" ] && exit 0

root=$(printf '%s' "$bead_json" | jq -r '.[0].metadata["gc.root_bead_id"] // empty' 2>/dev/null || true)
base="${GC_DASHBOARD_BASE:-http://127.0.0.1:8372/city/workspace/runs}"

# Subject stays a scannable one-liner (the inbox shows it in full); the body is
# the full human-readable summary, rendered from the SAME renderer that backs
# `gc dev-pack summary`.
if jq -e '.verdict' "$VF" >/dev/null 2>&1; then
    head=$(jq -r '.head_ref // "?"' "$VF")
    v=$(jq -r '.verdict // "?"' "$VF")
    fc=$(jq -r '.findings_count // 0' "$VF")
    subj="PR review $head: $v — $fc finding(s)"
else
    head=$(jq -r '.head_ref // "?"' "$VF")
    oc=$(jq -r '.outcome // "?"' "$VF")
    subj="Dynamic check $head: $oc"
fi
body=$("$SCRIPT_DIR/render-verdict.sh" "$VF" --bead "$BEAD" --run-url "${base}/${root}" --rig "${GC_RIG:-}") \
    || { printf '%s\n' "emit-verdict: WARN summary render failed; sending pointer-only body" >&2
         body="(summary render failed — full verdict: gc bd show $BEAD --json)"; }

# Best-effort: the step already closed; a mail hiccup must not fail the step.
"$GC" mail send "$TO" -s "$subj" -m "$body" || printf '%s\n' "emit-verdict: WARN notify to '$TO' failed (bead already closed)" >&2
