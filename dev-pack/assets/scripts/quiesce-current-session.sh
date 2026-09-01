#!/usr/bin/env bash
# Retire an ephemeral workflow session after its terminal emitter has closed the
# assigned attempt. Draining is a two-phase handshake: `runtime drain` requests the
# stop, while `runtime drain-ack` releases the pool slot. Completing both phases
# prevents the reconciler from delivering the stale trigger nudge and lets a max=1
# pool start its next queued assignment with a fresh trigger.
set -euo pipefail

GC="${GC_BIN:-gc}"
AGENT="${GC_AGENT:-${GC_AGENT_NAME:-}}"
[ -n "$AGENT" ] || exit 0
"$GC" runtime drain "$AGENT" >/dev/null 2>&1 || {
    printf 'workflow emitter: WARN could not quiesce session %s after close\n' "$AGENT" >&2
}
"$GC" runtime drain-ack "$AGENT" >/dev/null 2>&1 ||
    printf 'workflow emitter: WARN could not acknowledge drain for session %s after close\n' "$AGENT" >&2
