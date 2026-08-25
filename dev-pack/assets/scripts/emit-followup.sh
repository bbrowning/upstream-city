#!/usr/bin/env bash
# emit-followup.sh — finish a pr-followup step ATOMICALLY in ONE command: write
# output_json, stamp gc.followup_of (the root verdict bead this question chains
# from), CLOSE the bead, and (unless disabled) NOTIFY the human — threaded into
# the same mail conversation as the original verdict where one exists.
#
#   emit-followup.sh --bead <id> --root-bead <root> --answer-file <path.json> \
#       --outcome pass|fail [--failure-class none|transient|hard] \
#       [--failure-reason STR] [--reason CLOSE_MSG]
#
# THREADING: does NOT use `gc mail reply` — Provider.Reply addresses the new
# message back to the ORIGINAL SENDER of the message being replied to (the dead
# review-agent session), not to the human. Instead this sends a normal
# `gc mail send <to=human>` and splices the SAME thread:/reply-to: labels Reply
# would have produced onto the new message bead directly, inheriting the thread
# from the most recent prior message in this PR's follow-up chain (or the root
# verdict's own notify mail, on round 1). Requires the root bead — and every
# prior follow-up bead in the chain — to carry gc.notify_mail_id (stashed here,
# and by emit-verdict.sh on the root).
#
# NOTIFICATION IS OPERATOR POLICY, not the pack's: the mail goes to $GC_PR_NOTIFY_TO
# (default "human"). Set GC_PR_NOTIFY_TO="" to disable it, same as emit-verdict.sh.
set -euo pipefail

GC="${GC_BIN:-gc}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZE="$SCRIPT_DIR/normalize-pr-target.sh"
BEAD="" ; ROOT="" ; AF="" ; OUTCOME="pass" ; FCLASS="none" ; FREASON="" ; REASON=""

die() { printf '%s\n' "emit-followup: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --bead)            BEAD="${2:?}"; shift 2 ;;
        --bead=*)          BEAD="${1#*=}"; shift ;;
        --root-bead)       ROOT="${2:?}"; shift 2 ;;
        --root-bead=*)     ROOT="${1#*=}"; shift ;;
        --answer-file)     AF="${2:?}"; shift 2 ;;
        --answer-file=*)   AF="${1#*=}"; shift ;;
        --outcome)         OUTCOME="${2:?}"; shift 2 ;;
        --outcome=*)       OUTCOME="${1#*=}"; shift ;;
        --failure-class)   FCLASS="${2:?}"; shift 2 ;;
        --failure-class=*) FCLASS="${1#*=}"; shift ;;
        --failure-reason)  FREASON="${2:?}"; shift 2 ;;
        --failure-reason=*) FREASON="${1#*=}"; shift ;;
        --reason)          REASON="${2:?}"; shift 2 ;;
        --reason=*)        REASON="${1#*=}"; shift ;;
        -*)                die "unknown option '$1'" ;;
        *)                 die "unexpected argument '$1'" ;;
    esac
done

[ -n "$BEAD" ] || die "usage: --bead is required"
[ -n "$ROOT" ] || die "usage: --root-bead is required"
[ -n "$AF" ] && [ -f "$AF" ] || die "usage: --answer-file must be an existing file"
OUT=$(jq -c . "$AF") || die "answer file is not valid JSON: $AF"
pr=$(printf '%s' "$OUT" | jq -r '.pr // empty')
if [ -n "$pr" ]; then
    [ -x "$NORMALIZE" ] || die "target normalizer not found/executable: $NORMALIZE"
    PN=$("$NORMALIZE" "$pr" --rig "${GC_RIG:-vllm}" --rig-explicit) || exit $?
    pr=$(printf '%s' "$PN" | jq -r '.spec')
    OUT=$(printf '%s' "$OUT" | jq -c --arg pr "$pr" '.pr = $pr')
fi

# --- guard: --bead must be the caller's own step bead, never the workflow root
# or the (unrelated) --root-bead verdict bead. Both mistakes have happened: the
# workflow-root bead is where gc.var.* inputs live, which reads like "my bead"
# to an agent that didn't check kind — but emitting there leaves the real step
# bead open (blocking retry/finalize) AND fires a second human notification
# once the correct bead is emitted later.
bead_json=$("$GC" bd show "$BEAD" --json 2>/dev/null) || die "--bead $BEAD: cannot read bead"
bead_kind=$(printf '%s' "$bead_json" | jq -r '.[0].metadata["gc.kind"] // empty')
[ "$bead_kind" != "workflow" ] || die "--bead $BEAD is the workflow-root bead (gc.kind=workflow) — use your own step-bead id from 'gc prime', not this one"
[ "$BEAD" != "$ROOT" ] || die "--bead and --root-bead are the same ($BEAD) — --root-bead is the unrelated original verdict bead, never your own step bead"

# --- write metadata (MERGE — never --metadata '{…}', which wipes routing keys) ---
"$GC" bd update "$BEAD" --set-metadata "gc.output_json=$OUT" --set-metadata "gc.outcome=$OUTCOME" \
    --set-metadata "gc.followup_of=$ROOT"
if [ "$FCLASS" != "none" ]; then
    "$GC" bd update "$BEAD" --set-metadata "gc.failure_class=$FCLASS" --set-metadata "gc.failure_reason=$FREASON"
fi

# --- CLOSE the step ----------------------------------------------------------
if [ -z "$REASON" ]; then
    q=$(jq -r '.question // "?"' "$AF")
    REASON="follow-up: ${q:0:80}"
fi
"$GC" bd close "$BEAD" --reason "$REASON"

# --- NOTIFY (operator policy; default human, empty disables) ------------------
TO="${GC_PR_NOTIFY_TO-human}"
[ -z "$TO" ] && exit 0   # notification disabled by the operator

pr=$(printf '%s' "$OUT" | jq -r '.pr // "?"')
question=$(printf '%s' "$OUT" | jq -r '.question // "?"')
answer=$(printf '%s' "$OUT" | jq -r '.answer // "(no answer recorded)"')

subj="Follow-up on PR ${pr}: ${question:0:60}"
body=$(printf 'Q: %s\n\nA:\n%s\n\n---\nAsk another: gc dev-pack ask %s "<question>"\nFull record: gc bd show %s --json\n' \
    "$question" "$answer" "$pr" "$BEAD")

# --- Find the prior message in this PR's chain to thread against -------------
# The most recent prior follow-up on this root (excluding ourselves — we already
# carry gc.followup_of=$ROOT from the write above), else the root's own notify
# mail (stamped by emit-verdict.sh at review time).
prior_id=$(
    "$GC" bd list --all --json --metadata-field "gc.followup_of=$ROOT" -n 0 2>/dev/null \
        | jq -r --arg self "$BEAD" '
            [ .[]? | select(.id != $self) | select(.metadata["gc.notify_mail_id"] != null)
              | {id: .id, mail: .metadata["gc.notify_mail_id"],
                 ts: (.closed_at // .updated_at // .created_at // "")} ]
            | sort_by(.ts) | last | .mail // empty' 2>/dev/null || true
)
if [ -z "$prior_id" ]; then
    root_json=$("$GC" bd show "$ROOT" --json 2>/dev/null || true)
    prior_id=$(printf '%s' "$root_json" | jq -r '.[0].metadata["gc.notify_mail_id"] // empty' 2>/dev/null || true)
fi

# Best-effort: the step already closed; a mail hiccup must not fail the step.
mail_json=$("$GC" mail send "$TO" -s "$subj" -m "$body" --json 2>/dev/null) \
    || { printf '%s\n' "emit-followup: WARN notify to '$TO' failed (bead already closed)" >&2; mail_json=""; }
[ -n "$mail_json" ] || exit 0

new_id=$(printf '%s' "$mail_json" | jq -r '.id // empty' 2>/dev/null || true)
[ -n "$new_id" ] || exit 0

# Stash our own notify mail id so the NEXT round in this chain can thread off us.
"$GC" bd update "$BEAD" --set-metadata "gc.notify_mail_id=$new_id" \
    || printf '%s\n' "emit-followup: WARN could not stash gc.notify_mail_id" >&2

if [ -n "$prior_id" ]; then
    thread_id=$("$GC" mail peek "$prior_id" --json 2>/dev/null | jq -r '.message.thread_id // empty' 2>/dev/null || true)
    if [ -n "$thread_id" ]; then
        "$GC" bd update "$new_id" --set-labels "thread:$thread_id" --set-labels "reply-to:$prior_id" \
            || printf '%s\n' "emit-followup: WARN could not splice thread labels onto $new_id" >&2
    fi
fi
