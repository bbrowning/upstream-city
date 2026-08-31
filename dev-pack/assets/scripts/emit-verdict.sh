#!/usr/bin/env bash
# emit-verdict.sh — finish a review / dynamic-check step ATOMICALLY in ONE command:
# write output_json, set outcome, CLOSE the bead, and (unless disabled) NOTIFY the
# human. Closing and notifying are inseparable here, so a notification can never be
# a forgotten trailing step — completing the step IS notifying.
#
#   emit-verdict.sh --bead <id> --verdict-file <path.json> --outcome pass|fail \
#       [--failure-class none|transient|hard] [--failure-reason STR] [--reason CLOSE_MSG]
#       [--implementation-artifact-id ID ...all implementation provenance fields]
#
# Schema is auto-detected from the verdict JSON (by shape): `.resolutions` present ->
# pr-review-settle.v1 (divergence settle); else `.verdict` present -> pr-review.v1 /
# pr-review-quorum.v1 (review); else -> pr-review-dynamic.v1 (dynamic check).
# Notification content is DERIVED from the verdict JSON via render-verdict.sh (the same
# renderer `gc dev-pack summary` uses), so the human always gets the actual results.
#
# NOTIFICATION IS OPERATOR POLICY, not the pack's: the mail goes to $GC_PR_NOTIFY_TO
# (default "human"). Set GC_PR_NOTIFY_TO="" (e.g. in a [[rigs.patches]] env block on
# the reviewer/runner agent) to disable the pack's built-in notify and handle it your
# own way. Dashboard base is $GC_DASHBOARD_BASE (default the local supervisor UI).
set -euo pipefail

GC="${GC_BIN:-gc}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZE="$SCRIPT_DIR/normalize-pr-target.sh"
RESOLVE_LOCAL="$SCRIPT_DIR/resolve-local-change.sh"
BEAD="" ; VF="" ; OUTCOME="pass" ; FCLASS="none" ; FREASON="" ; REASON=""
VALIDATE_IMPL=0 ; IMPL_REF="" ; IMPL_ID="" ; IMPL_REPO="" ; IMPL_BRANCH=""
IMPL_REVISION="" ; IMPL_BASE="" ; IMPL_HEAD="" ; REVIEW_REPO="."

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
        --implementation-artifact-ref) IMPL_REF="${2-}"; shift 2 ;;
        --implementation-artifact-ref=*) IMPL_REF="${1#*=}"; shift ;;
        --implementation-artifact-id) VALIDATE_IMPL=1; IMPL_ID="${2-}"; shift 2 ;;
        --implementation-artifact-id=*) VALIDATE_IMPL=1; IMPL_ID="${1#*=}"; shift ;;
        --implementation-repository-id) IMPL_REPO="${2-}"; shift 2 ;;
        --implementation-repository-id=*) IMPL_REPO="${1#*=}"; shift ;;
        --implementation-branch) IMPL_BRANCH="${2-}"; shift 2 ;;
        --implementation-branch=*) IMPL_BRANCH="${1#*=}"; shift ;;
        --implementation-revision) IMPL_REVISION="${2-}"; shift 2 ;;
        --implementation-revision=*) IMPL_REVISION="${1#*=}"; shift ;;
        --implementation-base-sha) IMPL_BASE="${2-}"; shift 2 ;;
        --implementation-base-sha=*) IMPL_BASE="${1#*=}"; shift ;;
        --implementation-head-sha) IMPL_HEAD="${2-}"; shift 2 ;;
        --implementation-head-sha=*) IMPL_HEAD="${1#*=}"; shift ;;
        --repo) REVIEW_REPO="${2:?}"; shift 2 ;;
        --repo=*) REVIEW_REPO="${1#*=}"; shift ;;
        -*)               die "unknown option '$1'" ;;
        *)                die "unexpected argument '$1'" ;;
    esac
done

[ -n "$BEAD" ] || die "usage: --bead is required"
[ -n "$VF" ] && [ -f "$VF" ] || die "usage: --verdict-file must be an existing file"
OUT=$(jq -c . "$VF") || die "verdict file is not valid JSON: $VF"

# Local-change lane provenance is a controller contract, not reviewer prose. Validate
# it immediately before the atomic close against both the assigned formula values and
# a fresh artifact resolution. A failure closes this attempt as retryable so the
# formula controller can run its bounded retry; it never reaches synthesis as a pass.
retry_provenance_failure() {
    local detail="$1"
    "$GC" bd update "$BEAD" \
        --set-metadata "gc.outcome=fail" \
        --set-metadata "gc.failure_class=transient" \
        --set-metadata "gc.failure_reason=implementation-provenance-mismatch"
    "$GC" bd close "$BEAD" --reason "retry: implementation provenance mismatch ($detail)"
    die "implementation provenance mismatch: $detail; attempt closed for bounded retry"
}

if [ "$VALIDATE_IMPL" -eq 1 ]; then
    if [ -z "$IMPL_ID" ]; then
        printf '%s' "$OUT" | jq -e '.implementation_provenance == null' >/dev/null \
            || retry_provenance_failure "PR review must emit null implementation_provenance"
    else
        [ -n "$IMPL_REF" ] || retry_provenance_failure "assigned artifact_ref is empty"
        [ -n "$IMPL_REPO" ] || retry_provenance_failure "assigned repository_id is empty"
        [ -n "$IMPL_REVISION" ] || retry_provenance_failure "assigned revision is empty"
        [ -n "$IMPL_BASE" ] || retry_provenance_failure "assigned base_sha is empty"
        [ -n "$IMPL_HEAD" ] || retry_provenance_failure "assigned head_sha is empty"
        case "$IMPL_REVISION" in *[!0-9]*) retry_provenance_failure "assigned revision is not numeric" ;; esac

        expected=$(jq -cn --arg ref "$IMPL_REF" --arg id "$IMPL_ID" --arg repo "$IMPL_REPO" \
            --arg branch "$IMPL_BRANCH" --argjson revision "$IMPL_REVISION" \
            --arg base "$IMPL_BASE" --arg head "$IMPL_HEAD" \
            '{artifact_ref:$ref,artifact_id:$id,repository_id:$repo,branch:$branch,revision:$revision,base_sha:$base,head_sha:$head}')
        for field in artifact_ref artifact_id repository_id branch revision base_sha head_sha; do
            actual=$(printf '%s' "$OUT" | jq -c ".implementation_provenance.$field // null")
            wanted=$(printf '%s' "$expected" | jq -c ".$field")
            [ "$actual" = "$wanted" ] \
                || retry_provenance_failure "$field expected $wanted, got $actual"
        done

        [ -x "$RESOLVE_LOCAL" ] || retry_provenance_failure "local-change resolver unavailable"
        if [ "$IMPL_ID" = "explicit-local-ref" ]; then
            resolve_args=(--repo "$REVIEW_REPO" --rig "${GC_RIG:-vllm}" --head "$IMPL_REF" --base "$IMPL_BASE")
        else
            resolve_args=(--repo "$REVIEW_REPO" --rig "${GC_RIG:-vllm}" --artifact "$IMPL_REF" --require-internal-producer)
        fi
        if ! fresh=$("$RESOLVE_LOCAL" "${resolve_args[@]}" 2>&1); then
            retry_provenance_failure "fresh artifact resolution failed: $fresh"
        fi
        for mapping in artifact_id:artifact_id repository_id:repository.id branch:head.branch revision:revision.number base_sha:base.sha head_sha:head.sha; do
            field=${mapping%%:*}; path=${mapping#*:}
            actual=$(printf '%s' "$fresh" | jq -c ".$path // null")
            wanted=$(printf '%s' "$expected" | jq -c ".$field")
            [ "$actual" = "$wanted" ] \
                || retry_provenance_failure "fresh $field expected $wanted, got $actual"
        done
    fi
fi

# Treat agent-produced JSON as an untrusted handoff too. This guarantees newly
# stored verdicts and notification hints never reintroduce a compound PR alias.
head=$(printf '%s' "$OUT" | jq -r '.head_ref // empty')
if [ -n "$head" ]; then
    [ -x "$NORMALIZE" ] || die "target normalizer not found/executable: $NORMALIZE"
    HN=$("$NORMALIZE" "$head" --rig "${GC_RIG:-vllm}" --rig-explicit) || exit $?
    head=$(printf '%s' "$HN" | jq -r '.spec')
    OUT=$(printf '%s' "$OUT" | jq -c --arg head "$head" '.head_ref = $head')
fi

# --- write metadata (MERGE — never --metadata '{…}', which wipes routing keys) ---
"$GC" bd update "$BEAD" --set-metadata "gc.output_json=$OUT" --set-metadata "gc.outcome=$OUTCOME"
if [ "$FCLASS" != "none" ]; then
    "$GC" bd update "$BEAD" --set-metadata "gc.failure_class=$FCLASS" --set-metadata "gc.failure_reason=$FREASON"
fi

# Fail closed before close: prove the exact normalized verdict/outcome survived the
# metadata write. Empty/truncated storage can never become a successful logical step.
stored_bead=$("$GC" bd show "$BEAD" --json) || die "could not verify stored output for $BEAD"
stored_out=$(printf '%s' "$stored_bead" | jq -ce '
    (if type == "array" then .[0] else . end).metadata["gc.output_json"]
    | if type == "string" then fromjson else . end') \
    || die "stored gc.output_json is empty or invalid for $BEAD"
stored_outcome=$(printf '%s' "$stored_bead" | jq -er '
    (if type == "array" then .[0] else . end).metadata["gc.outcome"] // empty') \
    || die "stored gc.outcome is empty for $BEAD"
[ "$(printf '%s' "$stored_out" | jq -S -c .)" = "$(printf '%s' "$OUT" | jq -S -c .)" ] \
    || die "stored gc.output_json does not match submitted output for $BEAD"
[ "$stored_outcome" = "$OUTCOME" ] || die "stored gc.outcome does not match submitted outcome for $BEAD"

# --- CLOSE the step ----------------------------------------------------------
if [ -z "$REASON" ]; then
    if jq -e '.resolutions' "$VF" >/dev/null 2>&1; then
        REASON="settle: $(jq -r '.disputes_examined // (.resolutions | length) // 0' "$VF") dispute(s) — $(jq -r '[.resolutions[]?.resolution] | map(select(. == "resolved")) | length' "$VF") resolved, $(jq -r '[.resolutions[]?.resolution] | map(select(. == "refuted")) | length' "$VF") refuted"
    elif jq -e '.verdict' "$VF" >/dev/null 2>&1; then
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
# the compact per-finding digest, rendered from the SAME renderer that backs
# `gc dev-pack summary` (which also defaults to --brief). The body's footer points
# to `gc dev-pack summary <bead> --full` for the complete verdict on demand.
if printf '%s' "$OUT" | jq -e '.resolutions' >/dev/null 2>&1; then
    head=$(printf '%s' "$OUT" | jq -r '.head_ref // "?"')
    dn=$(jq -r '.disputes_examined // (.resolutions | length) // 0' "$VF")
    rn=$(jq -r '[.resolutions[]?.resolution] | map(select(. == "resolved")) | length' "$VF")
    fn=$(jq -r '[.resolutions[]?.resolution] | map(select(. == "refuted")) | length' "$VF")
    subj="PR settle $head: $dn dispute(s) — $rn resolved, $fn refuted"
elif printf '%s' "$OUT" | jq -e '.verdict' >/dev/null 2>&1; then
    head=$(printf '%s' "$OUT" | jq -r '.head_ref // "?"')
    v=$(jq -r '.verdict // "?"' "$VF")
    fc=$(jq -r '.findings_count // 0' "$VF")
    subj="PR review $head: $v — $fc finding(s)"
else
    head=$(printf '%s' "$OUT" | jq -r '.head_ref // "?"')
    oc=$(jq -r '.outcome // "?"' "$VF")
    subj="Dynamic check $head: $oc"
fi
body=$(printf '%s' "$OUT" | "$SCRIPT_DIR/render-verdict.sh" - --bead "$BEAD" --run-url "${base}/${root}" --rig "${GC_RIG:-}" --brief) \
    || { printf '%s\n' "emit-verdict: WARN summary render failed; sending pointer-only body" >&2
         body="(summary render failed — full verdict: gc bd show $BEAD --json)"; }

# Best-effort: the step already closed; a mail hiccup must not fail the step.
mail_json=$("$GC" mail send "$TO" -s "$subj" -m "$body" --json 2>/dev/null) \
    || { printf '%s\n' "emit-verdict: WARN notify to '$TO' failed (bead already closed)" >&2; mail_json=""; }

# Stash the sent mail's id so a later `gc dev-pack ask` follow-up can thread its
# answer into this same mail conversation (see emit-followup.sh).
if [ -n "$mail_json" ]; then
    mail_id=$(printf '%s' "$mail_json" | jq -r '.id // empty' 2>/dev/null || true)
    [ -n "$mail_id" ] && "$GC" bd update "$BEAD" --set-metadata "gc.notify_mail_id=$mail_id" \
        || printf '%s\n' "emit-verdict: WARN could not stash gc.notify_mail_id" >&2
fi
