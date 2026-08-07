#!/usr/bin/env bash
# vllm-testenv.sh — build a FAST, SMALL, CPU-only vLLM venv that can run vLLM's
# pure-python UNIT tests (parsers, engine logic, etc.) WITHOUT a GPU, without
# compiling CUDA/CPU kernels, and without the ~15GB CUDA torch stack.
#
#   vllm-testenv.sh [--src DIR] [--venv DIR] [options]   # prints <venv>/bin/python on success
#
# WHY THIS EXISTS: setting up a vLLM test env by hand is fumble-prone — ad-hoc
# sessions reach for system `pip`, forget `VLLM_VERSION_OVERRIDE` (so the build
# fails "unable to detect version"), install the full CUDA test set (15GB), or get
# false failures from vLLM's non-GPU teardown hook. This is the one blessed recipe
# (verified against vLLM's docs/CI + live runs). It is deliberately vLLM-SPECIFIC
# and self-contained so it can be reused from the pr-review runner AND from an
# ordinary Claude Code / shell session. The generic pr-review-pack never calls this
# directly — it consumes the venv via $GC_PR_TEST_VENV.
#
# WHAT IT DOES (default, no compile):
#   uv venv --python 3.12
#   uv pip install -r requirements/common.txt   --torch-backend cpu     (torch==2.x+cpu)
#   uv pip install pytest pytest-asyncio tblib
#   uv pip install -r requirements/build/cpu.txt --torch-backend cpu     (build backend)
#   VLLM_TARGET_DEVICE=empty VLLM_VERSION_OVERRIDE=<ver>+cpu uv pip install -e <src> --no-build-isolation
#     -> setup.py _no_device(): ext_modules=[]  => NO cmake/ninja/CUDA/Rust compile,
#        NO wheel download; `import vllm` works (kernels are lazy & optional).
#
# THE "+cpu" TRICK (why the default is footgun-free): vLLM's autouse test teardown
# (tests/conftest.py cleanup_fixture -> cleanup_dist_env_and_memory) calls
# torch.accelerator.empty_cache() UNLESS current_platform.is_cpu(). On a GPU-less
# box, a plain build resolves to UnspecifiedPlatform (is_cpu()==False), so the
# teardown raises "Cannot access accelerator device" and EVERY test false-fails in
# teardown. vLLM decides the platform from a "cpu" substring in the version string
# (vllm/platforms/__init__.py cpu_platform_plugin). So we tag the version "+cpu":
# current_platform -> CpuPlatform, is_cpu()==True, teardown skips the GPU path.
# This needs NO kernel compilation (the kernels stay absent; parser/logic unit
# tests never touch them; missing vllm._C is a warning, not an error). Verified:
# tests/parser/test_parse.py went from 19 passed + 19 teardown errors -> 19 passed.
#
# NETWORK: the BUILD needs egress (wheels) — run it with the proxy set. The TEST
# RUN should be network-stripped; tests that try to download (tokenizers,
# openai-harmony's rust reqwest, which does not honor the MITM proxy CA) will fail
# there — the caller classifies those as "could_not_verify", not a real failure.
#
# --compile: do a REAL CPU-kernel build (VLLM_TARGET_DEVICE=cpu; needs cmake+ninja,
# installed via build/cpu.txt; slower). Only needed for tests that exercise actual
# CPU kernels — parser/logic unit tests do NOT. setup.py tags "+cpu" itself here.
#
# Env (overridable): UV_CACHE_DIR (default /pvc/workspace/.uv-cache — keep on the
#   SAME btrfs filesystem as the venv so uv reflinks instead of copying), UV_BIN
#   (default uv), VLLM_TESTENV_EXTRA_PIP (extra space-separated pip pkgs/args).
set -euo pipefail

UV="${UV_BIN:-uv}"
SRC=""
VENV=""
CACHE="${UV_CACHE_DIR:-/pvc/workspace/.uv-cache}"
VERSION=""
COMPILE=0
FORCE=0

log() { printf '%s\n' "vllm-testenv: $*" >&2; }
die() { printf '%s\n' "vllm-testenv: ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --src)       SRC="${2:?--src needs a value}"; shift 2 ;;
        --src=*)     SRC="${1#*=}"; shift ;;
        --venv)      VENV="${2:?--venv needs a value}"; shift 2 ;;
        --venv=*)    VENV="${1#*=}"; shift ;;
        --cache)     CACHE="${2:?--cache needs a value}"; shift 2 ;;
        --cache=*)   CACHE="${1#*=}"; shift ;;
        --version)   VERSION="${2:?--version needs a value}"; shift 2 ;;
        --version=*) VERSION="${1#*=}"; shift ;;
        --compile)   COMPILE=1; shift ;;
        --force)     FORCE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        -*)          die "unknown option '$1'" ;;
        *)           [ -z "$SRC" ] && { SRC="$1"; shift; } || die "unexpected argument '$1'" ;;
    esac
done

# --- resolve SRC (default: $VLLM_SRC or CWD if it looks like a vLLM checkout) --
[ -z "$SRC" ] && SRC="${VLLM_SRC:-$PWD}"
SRC="$(cd "$SRC" 2>/dev/null && pwd)" || die "--src '$SRC' does not exist"
[ -f "$SRC/requirements/common.txt" ] && [ -d "$SRC/vllm" ] \
    || die "--src '$SRC' is not a vLLM checkout (no requirements/common.txt + vllm/)"

VENV="${VENV:-$SRC/.venv}"

# --- version: pin VLLM_VERSION_OVERRIDE (build sandbox lacks .git, so scm fails) -
if [ -z "$VERSION" ]; then
    VERSION="$(git -C "$SRC" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
    VERSION="${VERSION:-0.0.0}"
fi
# Ensure a "cpu" substring so current_platform.is_cpu()==True (footgun-free).
# --compile lets setup.py add "+cpu" itself; otherwise we tag it here.
EFF_VERSION="$VERSION"
if [ "$COMPILE" -ne 1 ]; then
    case "$EFF_VERSION" in
        *cpu*) ;;                                   # already tagged
        *+*)   EFF_VERSION="${EFF_VERSION}.cpu" ;;  # add to existing local segment
        *)     EFF_VERSION="${EFF_VERSION}+cpu" ;;  # new local version segment
    esac
fi
[ "$COMPILE" -eq 1 ] && TARGET_DEVICE="cpu" || TARGET_DEVICE="empty"

export UV_CACHE_DIR="$CACHE"
mkdir -p "$CACHE"
PY="$VENV/bin/python"

# --- idempotency: reuse a venv that already imports vllm on CPU -----------------
if [ "$FORCE" -ne 1 ] && [ -x "$PY" ] \
   && "$PY" -c 'import vllm; from vllm.platforms import current_platform; assert current_platform.is_cpu()' >/dev/null 2>&1; then
    log "reusing existing CPU venv at $VENV ($("$PY" -c 'import vllm; print("vllm",vllm.__version__)' 2>/dev/null))"
    printf '%s\n' "$PY"
    exit 0
fi

log "building CPU test venv (compile=$COMPILE) for $SRC -> $VENV (version=$EFF_VERSION, cache=$CACHE)"

"$UV" venv --python 3.12 "$VENV" >&2

"$UV" pip install --python "$VENV" -r "$SRC/requirements/common.txt" \
    --torch-backend cpu --index-strategy unsafe-best-match >&2

# shellcheck disable=SC2086
"$UV" pip install --python "$VENV" pytest pytest-asyncio tblib ${VLLM_TESTENV_EXTRA_PIP:-} >&2

"$UV" pip install --python "$VENV" -r "$SRC/requirements/build/cpu.txt" \
    --torch-backend cpu --index-strategy unsafe-best-match >&2

# VLLM_VERSION_OVERRIDE is REQUIRED: the editable-metadata build runs without .git.
VLLM_TARGET_DEVICE="$TARGET_DEVICE" VLLM_VERSION_OVERRIDE="$EFF_VERSION" \
    "$UV" pip install --python "$VENV" -e "$SRC" --no-build-isolation >&2

# --- verify: imports AND resolves to a CPU platform (footgun-free) --------------
"$PY" -c 'import vllm; from vllm.platforms import current_platform
assert current_platform.is_cpu(), f"platform is {type(current_platform).__name__}, not CPU"
print("vllm-testenv: import OK", vllm.__version__, type(current_platform).__name__)' >&2 \
    || die "built the venv but import/CPU-platform check failed"

log "ready: $PY"
printf '%s\n' "$PY"
