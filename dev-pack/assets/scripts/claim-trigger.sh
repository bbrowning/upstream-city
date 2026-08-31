#!/usr/bin/env bash
# Claim exactly the controller-provided trigger and only then stamp provenance.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=dispatch-guard.sh
source "$SCRIPT_DIR/dispatch-guard.sh"

GC=${GC_BIN:-gc}
TRIGGER=${GC_TRIGGER_BEAD_ID:-}
[ -n "$TRIGGER" ] || { dev_pack_guard_die 'GC_TRIGGER_BEAD_ID is empty'; exit $?; }

before=$(dev_pack_guard_bead_json "$TRIGGER") || exit $?
route=$(printf '%s' "$before" | jq -r \
    '(if type == "array" then .[0] else . end).metadata["gc.routed_to"] // empty')
if [ -n "$route" ] && [ -n "${GC_AGENT:-}" ] && [ "$route" != "$GC_AGENT" ]; then
    dev_pack_guard_die "trigger $TRIGGER is routed to $route, not $GC_AGENT"
    exit $?
fi

# The only claim in dev-pack startup is now mechanically bound to the exact id
# already validated above; no ready-list/fuzzy discovery can enter this path.
# Claim and provenance replacement are one bd mutation, so a successful claimant
# cannot expose stale session/worktree residue between two separate writes.
stamp=()
[ -z "${GC_SESSION_NAME:-}" ] || stamp+=(--set-metadata "gc.session_name=$GC_SESSION_NAME")
work_dir=$(pwd -P)
[ -z "$work_dir" ] || stamp+=(--set-metadata "gc.work_dir=$work_dir")
"$GC" bd update "$TRIGGER" --claim "${stamp[@]}" >/dev/null
after=$(dev_pack_guard_bead_json "$TRIGGER") || exit $?
owner=$(printf '%s' "$after" | jq -r '(if type == "array" then .[0] else . end).assignee // empty')
expected_owner=${GC_SESSION_NAME:-${BEADS_ACTOR:-}}
[ -z "$expected_owner" ] || [ "$owner" = "$expected_owner" ] \
    || { dev_pack_guard_die "claim owner $owner does not match session $expected_owner"; exit $?; }
stored_name=$(printf '%s' "$after" | jq -r '(if type == "array" then .[0] else . end).metadata["gc.session_name"] // empty')
[ -z "${GC_SESSION_NAME:-}" ] || [ "$stored_name" = "$GC_SESSION_NAME" ] \
    || { dev_pack_guard_die "session provenance did not commit with claim for $TRIGGER"; exit $?; }
stored_dir=$(printf '%s' "$after" | jq -r '(if type == "array" then .[0] else . end).metadata["gc.work_dir"] // empty')
[ "$stored_dir" = "$work_dir" ] \
    || { dev_pack_guard_die "work-dir provenance did not commit with claim for $TRIGGER"; exit $?; }

printf '%s\n' "$TRIGGER"
