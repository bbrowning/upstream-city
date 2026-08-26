#!/usr/bin/env bash
# feature — kick off a single-lane feature implementation without hand-typing the sling.
#
#   gc dev-pack feature <bead> [options]
#
# Resolves the RIG (explicit --rig wins, else inferred from the bead prefix, e.g.
# vllm-123 -> vllm), then slings the feature-dev formula to <rig>/feature-dev, which
# implements and commits the assignment on a local paude/<bead> branch in its own
# worktree. The operator exports the commit; the arc closes on a real checkpoint.
#
# Env (provided by gc): GC_CITY_PATH, GC_BIN.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"

RIG="" ; BASE="origin/main" ; BEAD="" ; DRYRUN="no"

usage() {
    cat <<'EOF'
usage: gc dev-pack feature <bead> [options]

Resolve the rig (--rig, else inferred from the bead prefix) and sling the
feature-dev formula to <rig>/feature-dev.

  --rig NAME     run in this rig (default: infer from the bead prefix)
  --base REF     branch point / merge target (default: origin/main)
  --dry-run      print the gc sling command without running it
  -h, --help
EOF
}
die() { printf '%s\n' "feature: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)      RIG="${2:?}"; shift 2 ;;
        --rig=*)    RIG="${1#*=}"; shift ;;
        --base)     BASE="${2:?}"; shift 2 ;;
        --base=*)   BASE="${1#*=}"; shift ;;
        --dry-run)  DRYRUN="yes"; shift ;;
        -h|--help)  usage; exit 0 ;;
        --)         shift; break ;;
        -*)         die "unknown option '$1'" ;;
        *)          if [ -z "$BEAD" ]; then BEAD="$1"; shift; else die "unexpected argument '$1'"; fi ;;
    esac
done
[ $# -eq 0 ] || { [ -z "$BEAD" ] && BEAD="$1"; }
[ -n "$BEAD" ] || { usage >&2; die "missing <bead>"; }

# Resolve the rig: explicit --rig wins; else infer from the bead prefix (<rig>-<n>).
if [ -z "$RIG" ]; then
    RIG="${BEAD%-*}"
    [ -n "$RIG" ] && [ "$RIG" != "$BEAD" ] || die "cannot infer rig from bead '$BEAD'; pass --rig NAME"
fi

set -- "$RIG/feature-dev" feature-dev --formula \
    --var "bead_id=$BEAD" --var "base=$BASE" \
    --title "feature-dev: $BEAD" --json

if [ "$DRYRUN" = "yes" ]; then
    printf 'DRY RUN — would run (rig=%s):\n  %s --rig %s sling' "$RIG" "$GC" "$RIG"
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
    exit 0
fi

printf '%s\n' "feature: slinging feature-dev for '$BEAD' in rig '$RIG'" >&2
exec "$GC" --city "$CITY" --rig "$RIG" sling "$@"
