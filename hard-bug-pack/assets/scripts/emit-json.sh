#!/usr/bin/env bash
# emit-json.sh — finish a hard-bug step ATOMICALLY in one command: MERGE-write the
# step's gc.output_json, set gc.outcome (+ optional failure class/reason + schema),
# CLOSE the bead, and OPTIONALLY notify. Schema-agnostic sibling of pr-review-pack's
# emit-verdict.sh: same durable-write + close skeleton, but no verdict rendering —
# the hard-bug coordinator composes its own richer human mail, so notification here
# is opt-in (pass --notify to enable a terse pointer mail).
#
#   emit-json.sh --bead <id> --json-file <path.json> [--schema NAME] \
#       --outcome pass|fail [--failure-class none|transient|hard] \
#       [--failure-reason STR] [--reason CLOSE_MSG] [--notify TO] [--subject STR]
#
# The write is a metadata MERGE (--set-metadata), NEVER --metadata '{...}', which
# would wipe the routing keys the controller set (gc.run_target, gc.root_bead_id,
# gc.output_json_schema, ...). Closing after the merge means a finished step always
# carries its durable output.
set -euo pipefail

GC="${GC_BIN:-gc}"
BEAD="" ; JF="" ; SCHEMA="" ; OUTCOME="pass" ; FCLASS="none" ; FREASON="" ; REASON="" ; NOTIFY="" ; SUBJECT=""

die() { printf '%s\n' "emit-json: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --bead)             BEAD="${2:?}"; shift 2 ;;
        --bead=*)           BEAD="${1#*=}"; shift ;;
        --json-file)        JF="${2:?}"; shift 2 ;;
        --json-file=*)      JF="${1#*=}"; shift ;;
        --schema)           SCHEMA="${2:?}"; shift 2 ;;
        --schema=*)         SCHEMA="${1#*=}"; shift ;;
        --outcome)          OUTCOME="${2:?}"; shift 2 ;;
        --outcome=*)        OUTCOME="${1#*=}"; shift ;;
        --failure-class)    FCLASS="${2:?}"; shift 2 ;;
        --failure-class=*)  FCLASS="${1#*=}"; shift ;;
        --failure-reason)   FREASON="${2:?}"; shift 2 ;;
        --failure-reason=*) FREASON="${1#*=}"; shift ;;
        --reason)           REASON="${2:?}"; shift 2 ;;
        --reason=*)         REASON="${1#*=}"; shift ;;
        --notify)           NOTIFY="${2:?}"; shift 2 ;;
        --notify=*)         NOTIFY="${1#*=}"; shift ;;
        --subject)          SUBJECT="${2:?}"; shift 2 ;;
        --subject=*)        SUBJECT="${1#*=}"; shift ;;
        -*)                 die "unknown option '$1'" ;;
        *)                  die "unexpected argument '$1'" ;;
    esac
done

[ -n "$BEAD" ] || die "usage: --bead is required"
[ -n "$JF" ] && [ -f "$JF" ] || die "usage: --json-file must be an existing file"
OUT=$(jq -c . "$JF") || die "json file is not valid JSON: $JF"

# --- write metadata (MERGE — never --metadata '{…}', which wipes routing keys) ---
"$GC" bd update "$BEAD" --set-metadata "gc.output_json=$OUT" --set-metadata "gc.outcome=$OUTCOME"
[ -n "$SCHEMA" ] && "$GC" bd update "$BEAD" --set-metadata "gc.output_json_schema=$SCHEMA"
if [ "$FCLASS" != "none" ]; then
    "$GC" bd update "$BEAD" --set-metadata "gc.failure_class=$FCLASS" --set-metadata "gc.failure_reason=$FREASON"
fi

# --- CLOSE the step ----------------------------------------------------------
[ -n "$REASON" ] || REASON="hard-bug step: ${SCHEMA:-output} ($OUTCOME)"
"$GC" bd close "$BEAD" --reason "$REASON"

# --- NOTIFY (opt-in; the coordinator usually composes its own richer mail) ----
[ -n "$NOTIFY" ] || exit 0
[ -n "$SUBJECT" ] || SUBJECT="hard-bug: ${SCHEMA:-step} $OUTCOME ($BEAD)"
# Best-effort: the step already closed; a mail hiccup must not fail the step.
"$GC" mail send "$NOTIFY" -s "$SUBJECT" -m "$(printf 'Step %s closed: %s\n\n%s\n' "$BEAD" "$OUTCOME" "$OUT")" \
    || printf '%s\n' "emit-json: WARN notify to '$NOTIFY' failed (bead already closed)" >&2
