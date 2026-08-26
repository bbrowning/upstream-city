#!/usr/bin/env bash
# Audit every dev-pack surface that can route or instruct implementation work.
set -euo pipefail

PACK_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

fail() { printf 'local-only audit: %s\n' "$*" >&2; exit 1; }

surfaces=(
    "$PACK_ROOT/agents"
    "$PACK_ROOT/formulas"
    "$PACK_ROOT/commands"
    "$PACK_ROOT/template-fragments"
    "$PACK_ROOT/pack.toml"
    "$PACK_ROOT/README.md"
)

implementation_contracts=(
    "$PACK_ROOT/agents/feature-dev"
    "$PACK_ROOT/agents/bug-worker-a"
    "$PACK_ROOT/agents/bug-worker-b"
    "$PACK_ROOT/formulas/feature-dev.toml"
    "$PACK_ROOT/formulas/hard-bug-finalize.toml"
    "$PACK_ROOT/commands/feature"
)

for path in "${surfaces[@]}"; do
    [ -e "$path" ] || fail "missing audited surface: $path"
done

# Commands that mutate Git hosting or publish Git refs are forbidden even when
# presented as best-effort, retry, recovery, fallback, or direct-routing advice.
remote_write_re='git[[:space:]]+push|gh[[:space:]]+(pr|issue)[[:space:]]+(create|edit|merge|close|reopen|comment|review)|gh[[:space:]]+api([^[:alnum:]]|$).*((--method|-X)[[:space:]]*(POST|PUT|PATCH|DELETE)|(-f|--field|--raw-field)[[:space:]])'
if grep -ERni --include='*.toml' --include='*.md' --include='*.sh' \
    "$remote_write_re" "${surfaces[@]}"; then
    fail "remote-write command found"
fi

# Implementation work must consume refs already present in the shared repo.
# A fetch fallback makes the supposedly local handoff depend on publication.
if grep -ERni --include='*.toml' --include='*.md' --include='*.sh' \
    'git[[:space:]]+fetch|FETCH_HEAD' "${implementation_contracts[@]}"; then
    fail "remote-read fallback found in an implementation contract"
fi

# Legacy publication-oriented schema fields are not valid durable output.
if grep -ERni --include='*.toml' --include='*.md' --include='*.sh' \
    '(^|[^[:alnum:]_])(pushed|pr_url)([^[:alnum:]_]|$)' \
    "${surfaces[@]}"; then
    fail "publication-oriented output contract found"
fi

require_text() {
    local file=$1 pattern=$2 label=$3
    grep -Eqi "$pattern" "$file" || fail "$label missing from $file"
}

# Standing prompts and direct formula routing must each be safe independently.
for file in \
    "$PACK_ROOT/agents/feature-dev/prompt.template.md" \
    "$PACK_ROOT/agents/bug-worker-a/prompt.template.md" \
    "$PACK_ROOT/formulas/feature-dev.toml" \
    "$PACK_ROOT/formulas/hard-bug-finalize.toml"; do
    require_text "$file" 'strictly local-only' 'local-only policy'
    require_text "$file" 'head_sha|HEAD SHA' 'immutable head handoff'
    require_text "$file" 'worktree_state|worktree state' 'worktree-state handoff'
done

for file in \
    "$PACK_ROOT/agents/feature-dev/agent.toml" \
    "$PACK_ROOT/agents/bug-worker-a/agent.toml" \
    "$PACK_ROOT/agents/bug-worker-b/agent.toml"; do
    require_text "$file" '^nudge[[:space:]]*=.*[Ll]ocal-only' 'local-only nudge'
    require_text "$file" '^nudge[[:space:]]*=.*HEAD SHA' 'SHA-bearing nudge'
done

require_text "$PACK_ROOT/agents/feature-dev/prompt.template.md" 'Handoff \(context cycling\)' 'feature recovery handoff'
require_text "$PACK_ROOT/agents/bug-worker-a/prompt.template.md" 'Handoff \(context cycling\)' 'bug recovery handoff'
require_text "$PACK_ROOT/agents/bug-worker-a/prompt.template.md" 'rev-parse <branch>.*<head_sha>' 'local SHA cross-review guard'
require_text "$PACK_ROOT/formulas/hard-bug-finalize.toml" 'rev-parse <branch>.*head_sha' 'formula SHA cross-review guard'
require_text "$PACK_ROOT/pack.toml" 'operator actions' 'pack-level operator boundary'
require_text "$PACK_ROOT/README.md" 'operator extracts commits' 'operator export documentation'

printf 'local-only audit: ok\n'
