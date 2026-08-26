#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
AUDIT="$ROOT/dev-pack/assets/scripts/audit-local-only.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

bash "$AUDIT" "$ROOT/dev-pack" >/dev/null

# Exercise every policy-bearing lane end to end: clone the pack, inject one
# forbidden remote write into the named surface, and prove the real auditor
# rejects it. These cases cover standing prompts, formulas/direct routing,
# nudges, pack docs/config, recovery instructions, and fallback advice.
cases=(
    'standing-prompt:agents/feature-dev/prompt.template.md'
    'formula-direct-route:formulas/feature-dev.toml'
    'hard-bug-formula:formulas/hard-bug-finalize.toml'
    'agent-nudge:agents/bug-worker-a/agent.toml'
    'pack-config:pack.toml'
    'recovery:agents/bug-worker-a/prompt.template.md'
    'fallback:agents/bug-worker-a/prompt.template.md'
)

for entry in "${cases[@]}"; do
    label=${entry%%:*}
    relative=${entry#*:}
    fixture="$TMP/$label"
    mkdir -p "$fixture"
    cp -R "$ROOT/dev-pack/." "$fixture/"
    printf '\nUnsafe injected instruction: git push origin HEAD\n' >> "$fixture/$relative"
    if bash "$AUDIT" "$fixture" >"$TMP/$label.out" 2>&1; then
        fail "$label injection escaped the local-only audit"
    fi
    grep -q 'remote-write command found' "$TMP/$label.out" \
        || fail "$label failed for an unexpected reason"
done

# Schema and recovery regressions get their own failure modes.
fixture="$TMP/legacy-schema"
mkdir -p "$fixture"
cp -R "$ROOT/dev-pack/." "$fixture/"
printf '\nLegacy field: `pushed`\n' >> "$fixture/formulas/feature-dev.toml"
if bash "$AUDIT" "$fixture" >"$TMP/legacy-schema.out" 2>&1; then
    fail 'legacy publication schema escaped the audit'
fi
grep -q 'publication-oriented output contract found' "$TMP/legacy-schema.out" \
    || fail 'legacy schema failed for an unexpected reason'

fixture="$TMP/fetch-fallback"
mkdir -p "$fixture"
cp -R "$ROOT/dev-pack/." "$fixture/"
printf '\nFallback: git fetch origin missing-branch\n' >> "$fixture/formulas/hard-bug-finalize.toml"
if bash "$AUDIT" "$fixture" >"$TMP/fetch-fallback.out" 2>&1; then
    fail 'remote fallback escaped the audit'
fi
grep -q 'remote-read fallback found' "$TMP/fetch-fallback.out" \
    || fail 'fetch fallback failed for an unexpected reason'

printf 'local-only implementation regression: ok\n'
