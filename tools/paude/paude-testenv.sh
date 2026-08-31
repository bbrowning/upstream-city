#!/usr/bin/env bash
# Build or reuse Paude's frozen Python 3.11 development environment and print
# the Python wrapper that review checks should execute.
set -euo pipefail

UV="${UV_BIN:-uv}"
SRC=""
VENV=""
CACHE="${UV_CACHE_DIR:-/pvc/workspace/.uv-cache}"
FORCE=0

log() { printf '%s\n' "paude-testenv: $*" >&2; }
die() { printf '%s\n' "paude-testenv: ERROR: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --src) SRC="${2:?--src needs a value}"; shift 2 ;;
        --src=*) SRC="${1#*=}"; shift ;;
        --venv) VENV="${2:?--venv needs a value}"; shift 2 ;;
        --venv=*) VENV="${1#*=}"; shift ;;
        --cache) CACHE="${2:?--cache needs a value}"; shift 2 ;;
        --cache=*) CACHE="${1#*=}"; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help)
            printf '%s\n' \
                'usage: paude-testenv.sh [--src DIR] [--venv DIR] [--cache DIR] [--force]'
            exit 0
            ;;
        -*) die "unknown option '$1'" ;;
        *) [ -z "$SRC" ] && SRC="$1" && shift || die "unexpected argument '$1'" ;;
    esac
done

SRC="${SRC:-$PWD}"
SRC="$(cd "$SRC" 2>/dev/null && pwd)" || die "--src '$SRC' does not exist"
[ -f "$SRC/pyproject.toml" ] && [ -f "$SRC/uv.lock" ] \
    || die "--src '$SRC' is not a Paude checkout (pyproject.toml and uv.lock required)"

VENV="${VENV:-$SRC/.venv}"
RUNTIME="$VENV/.paude-runtime"
WRAPPER="$VENV/bin/python"
MARKER="$VENV/.paude-lock.sha256"
LOCK_SHA="$(sha256sum "$SRC/pyproject.toml" "$SRC/uv.lock" | sha256sum | cut -d' ' -f1)"

export UV_CACHE_DIR="$CACHE"
mkdir -p "$CACHE" "$VENV/bin"

write_wrapper() {
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'unset NO_COLOR' \
        'export FORCE_COLOR=1' \
        'export TERM=xterm-256color' \
        "exec \"$RUNTIME/bin/python\" \"\$@\"" \
        >"$WRAPPER"
    chmod 755 "$WRAPPER"
}

if [ "$FORCE" -ne 1 ] && [ -x "$RUNTIME/bin/python" ] \
    && [ "$(cat "$MARKER" 2>/dev/null || true)" = "$LOCK_SHA" ]; then
    write_wrapper
    if "$WRAPPER" -c 'import sys, paude, pytest; assert sys.version_info[:2] == (3, 11)' \
        >/dev/null 2>&1; then
        log "reusing frozen Python 3.11 environment at $RUNTIME"
        printf '%s\n' "$WRAPPER"
        exit 0
    fi
fi

log "syncing frozen Python 3.11 dev environment for $SRC (cache=$CACHE)"
UV_PROJECT_ENVIRONMENT="$RUNTIME" "$UV" sync \
    --project "$SRC" --frozen --group dev --python 3.11 >&2
write_wrapper
printf '%s\n' "$LOCK_SHA" >"$MARKER"

"$WRAPPER" -c 'import os, sys, paude, pytest
assert sys.version_info[:2] == (3, 11)
assert "NO_COLOR" not in os.environ
assert os.environ["FORCE_COLOR"] == "1"
assert os.environ["TERM"] == "xterm-256color"' \
    || die "prepared environment failed its import, version, or color check"

log "ready: $WRAPPER"
printf '%s\n' "$WRAPPER"
