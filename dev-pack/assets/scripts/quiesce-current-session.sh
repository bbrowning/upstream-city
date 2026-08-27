#!/usr/bin/env bash
# Retire an ephemeral workflow session after its terminal emitter has closed the
# assigned attempt. This prevents the reconciler from delivering the stale trigger
# nudge while the controller mirrors the attempt onto its logical retry bead.
set -euo pipefail

GC="${GC_BIN:-gc}"
AGENT="${GC_AGENT:-${GC_AGENT_NAME:-}}"
[ -n "$AGENT" ] || exit 0
"$GC" runtime drain "$AGENT" >/dev/null 2>&1 || {
    printf 'workflow emitter: WARN could not quiesce session %s after close\n' "$AGENT" >&2
    exit 0
}
