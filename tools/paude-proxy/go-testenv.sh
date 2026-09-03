#!/usr/bin/env bash
# Install or reuse the pinned Go toolchain and golangci-lint release used by
# paude-proxy development, then print the go executable path. Tools and Go's
# build/module caches live on the shared city volume for reuse by all worktrees.
set -euo pipefail

VERSION="1.23.12"
ARCHIVE_SHA256="78852b2e96f47e46296e680e70cae993a6b3b61e01ffdb15386016cde6ba8c19"
ARCHIVE_URL="https://github.com/actions/go-versions/releases/download/1.23.12-16792118003/go-1.23.12-linux-x64.tar.gz"
LINTER_VERSION="2.12.2"
LINTER_ARCHIVE_SHA256="8df580d2670fed8fa984aac0507099af8df275e665215f5c7a2ae3943893a553"
LINTER_ARCHIVE_URL="https://github.com/golangci/golangci-lint/releases/download/v$LINTER_VERSION/golangci-lint-$LINTER_VERSION-linux-amd64.tar.gz"
ROOT="${GO_TESTENV_ROOT:-/pvc/workspace/.go}"
SRC=""
FORCE=0

log() { printf '%s\n' "paude-proxy-go-testenv: $*" >&2; }
die() { printf '%s\n' "paude-proxy-go-testenv: ERROR: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --src) SRC="${2:?--src needs a value}"; shift 2 ;;
        --src=*) SRC="${1#*=}"; shift ;;
        # Accepted for compatibility with GC_PREPARE_TEST_ENV callers. Go's
        # environment is shared rather than installed inside each worktree.
        --venv) shift 2 ;;
        --venv=*) shift ;;
        --root) ROOT="${2:?--root needs a value}"; shift 2 ;;
        --root=*) ROOT="${1#*=}"; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help)
            printf '%s\n' \
                'usage: go-testenv.sh [--src DIR] [--root DIR] [--force]'
            exit 0
            ;;
        -*) die "unknown option '$1'" ;;
        *) [ -z "$SRC" ] && SRC="$1" && shift || die "unexpected argument '$1'" ;;
    esac
done

SRC="${SRC:-$PWD}"
SRC="$(cd "$SRC" 2>/dev/null && pwd)" || die "--src '$SRC' does not exist"
[ -f "$SRC/go.mod" ] || die "--src '$SRC' is not a Go module (go.mod required)"

case "$(uname -s):$(uname -m)" in
    Linux:x86_64) ;;
    *) die "the pinned toolchain currently supports Linux x86_64 only" ;;
esac

TOOLCHAIN="$ROOT/toolchains/go$VERSION"
DOWNLOADS="$ROOT/downloads"
ARCHIVE="$DOWNLOADS/go-$VERSION-linux-x64.tar.gz"
LINTER_ROOT="$ROOT/tools/golangci-lint-$LINTER_VERSION"
LINTER_ARCHIVE="$DOWNLOADS/golangci-lint-$LINTER_VERSION-linux-amd64.tar.gz"
LINTER_BIN="$LINTER_ROOT/golangci-lint"
LOCK="$ROOT/.install.lock"
USER_BIN="${GO_TESTENV_USER_BIN:-/home/paude/.local/bin}"
GO_WRAPPER="$USER_BIN/go"

mkdir -p "$ROOT/toolchains" "$ROOT/tools" "$DOWNLOADS" "$ROOT/cache/build" "$ROOT/cache/mod" "$USER_BIN"
exec 9>"$LOCK"
flock 9

valid_toolchain() {
    [ -x "$TOOLCHAIN/bin/go" ] \
        && [ "$($TOOLCHAIN/bin/go version 2>/dev/null || true)" = "go version go$VERSION linux/amd64" ]
}

valid_linter() {
    [ -x "$LINTER_BIN" ] \
        && "$LINTER_BIN" version 2>/dev/null | grep -Eq "(^| )$LINTER_VERSION( |$)"
}

if [ "$FORCE" -eq 1 ] || ! valid_toolchain; then
    if [ ! -f "$ARCHIVE" ] \
        || [ "$(sha256sum "$ARCHIVE" | cut -d' ' -f1)" != "$ARCHIVE_SHA256" ]; then
        tmp_archive="$(mktemp "$DOWNLOADS/.go-$VERSION.XXXXXX")"
        log "downloading Go $VERSION from $ARCHIVE_URL"
        if ! curl -fL --retry 3 --connect-timeout 15 --max-time 180 \
            -o "$tmp_archive" "$ARCHIVE_URL"; then
            rm -f "$tmp_archive"
            die "toolchain download failed"
        fi
        [ "$(sha256sum "$tmp_archive" | cut -d' ' -f1)" = "$ARCHIVE_SHA256" ] \
            || { rm -f "$tmp_archive"; die "toolchain archive checksum mismatch"; }
        mv "$tmp_archive" "$ARCHIVE"
    fi

    extract_dir="$(mktemp -d "$ROOT/toolchains/.go$VERSION.XXXXXX")"
    trap 'rm -rf "$extract_dir"' EXIT
    log "installing Go $VERSION at $TOOLCHAIN"
    tar -xzf "$ARCHIVE" -C "$extract_dir"
    rm -rf "$TOOLCHAIN"
    mv "$extract_dir" "$TOOLCHAIN"
    trap - EXIT
    valid_toolchain || die "installed toolchain failed its version check"
fi

if [ "$FORCE" -eq 1 ] || ! valid_linter; then
    if [ ! -f "$LINTER_ARCHIVE" ] \
        || [ "$(sha256sum "$LINTER_ARCHIVE" | cut -d' ' -f1)" != "$LINTER_ARCHIVE_SHA256" ]; then
        tmp_archive="$(mktemp "$DOWNLOADS/.golangci-lint-$LINTER_VERSION.XXXXXX")"
        log "downloading golangci-lint $LINTER_VERSION from $LINTER_ARCHIVE_URL"
        if ! curl -fL --retry 3 --connect-timeout 15 --max-time 180 \
            -o "$tmp_archive" "$LINTER_ARCHIVE_URL"; then
            rm -f "$tmp_archive"
            die "golangci-lint download failed"
        fi
        [ "$(sha256sum "$tmp_archive" | cut -d' ' -f1)" = "$LINTER_ARCHIVE_SHA256" ] \
            || { rm -f "$tmp_archive"; die "golangci-lint archive checksum mismatch"; }
        mv "$tmp_archive" "$LINTER_ARCHIVE"
    fi

    extract_dir="$(mktemp -d "$ROOT/tools/.golangci-lint-$LINTER_VERSION.XXXXXX")"
    trap 'rm -rf "$extract_dir"' EXIT
    log "installing golangci-lint $LINTER_VERSION at $LINTER_ROOT"
    tar -xzf "$LINTER_ARCHIVE" -C "$extract_dir"
    mv "$extract_dir/golangci-lint-$LINTER_VERSION-linux-amd64/golangci-lint" \
        "$extract_dir/golangci-lint"
    rm -rf "$extract_dir/golangci-lint-$LINTER_VERSION-linux-amd64"
    rm -rf "$LINTER_ROOT"
    mv "$extract_dir" "$LINTER_ROOT"
    trap - EXIT
    valid_linter || die "installed golangci-lint failed its version check"
fi

# Keep Go's mutable state off individual worktrees and prevent the go command
# from silently fetching a different toolchain when the module directive moves.
wrapper_tmp="$(mktemp "$USER_BIN/.go.XXXXXX")"
cat >"$wrapper_tmp" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export GOCACHE="\${GOCACHE:-$ROOT/cache/build}"
export GOMODCACHE="\${GOMODCACHE:-$ROOT/cache/mod}"
export GOPROXY="\${GOPROXY:-https://proxy.golang.org,direct}"
export GOTOOLCHAIN="\${GOTOOLCHAIN:-local}"
exec "$TOOLCHAIN/bin/go" "\$@"
EOF
chmod 755 "$wrapper_tmp"
mv "$wrapper_tmp" "$GO_WRAPPER"
ln -sfn "$TOOLCHAIN/bin/gofmt" "$USER_BIN/gofmt"
ln -sfn "$LINTER_BIN" "$USER_BIN/golangci-lint"

log "ready: $($GO_WRAPPER version)"
log "ready: $($LINTER_BIN version | head -n 1)"
printf '%s\n' "$GO_WRAPPER"
