#!/usr/bin/env bash
# Run the dependency-free persona selector without consulting the target repo's
# Python project or creating a worktree-local environment/cache.
set -euo pipefail

CITY="${GC_CITY_PATH:-${GC_CITY:-}}"
[ -n "$CITY" ] || { printf 'select-personas: GC_CITY_PATH is required\n' >&2; exit 2; }
UV_BIN="${GC_PERSONA_UV:-$(command -v uv || true)}"
[ -n "$UV_BIN" ] || { printf 'select-personas: uv is required for the city-owned selector\n' >&2; exit 2; }
SCRIPT="$CITY/dev-pack/assets/scripts/persona-lifecycle.py"
CACHE="${GC_PERSONA_CACHE_DIR:-$CITY/.gc/runtime/dev-pack-persona-cache}"
WORKTREE=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    WORKTREE=$(git rev-parse --show-toplevel)
    [ -z "$(git status --porcelain=v1 --untracked-files=all)" ] || {
        printf 'select-personas: read-only preflight requires a clean worktree baseline\n' >&2
        exit 2
    }
    ignored_before=$(git status --porcelain=v1 --untracked-files=all --ignored=matching)
    resolved_cache=$(realpath -m "$CACHE")
    case "$resolved_cache/" in
        "$WORKTREE/"*) printf 'select-personas: cache must be external to target worktree: %s\n' "$resolved_cache" >&2; exit 2 ;;
    esac
    verify_exit() {
        rc=$?
        ignored_after=$(git status --porcelain=v1 --untracked-files=all --ignored=matching)
        if [ -n "$(git status --porcelain=v1 --untracked-files=all)" ] || \
           [ "$ignored_after" != "$ignored_before" ]; then
            printf 'select-personas: selector mutated the target worktree\n' >&2
            exit 2
        fi
        exit "$rc"
    }
    trap verify_exit EXIT
fi
mkdir -p "$CACHE"

"$UV_BIN" --cache-dir "$CACHE" run --no-project \
    --python "${GC_PERSONA_PYTHON:-$(command -v python3)}" "$SCRIPT" select "$@"
