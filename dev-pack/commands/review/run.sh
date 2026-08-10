#!/usr/bin/env bash
# review — kick off a posture-gated PR review without hand-typing the sling.
#
#   gc dev-pack review <PR-number | ref> [options]
#
# Slings the pr-review formula (triage -> posture-gated read-only review) for the
# given PR/ref to <rig>/pr-reviewer. The verdict lands in the human inbox
# (`gc mail check`) and can be re-rendered later with `gc dev-pack summary <bead|PR>`.
#
# Env (provided by gc): GC_CITY_PATH, GC_BIN.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"

RIG="vllm" ; BASE="origin/main" ; SPEC="" ; DRYRUN="no"

usage() {
    cat <<'EOF'
usage: gc dev-pack review <PR-number | ref> [options]

Sling the pr-review formula (triage -> posture-gated review) to <rig>/pr-reviewer.

  --rig NAME     rig the PR belongs to           (default: vllm)
  --base REF     baseline the diff is against     (default: origin/main)
  --dry-run      print the gc sling command without running it
  -h, --help
EOF
}
die() { printf '%s\n' "review: $*" >&2; exit 2; }

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
        *)          if [ -z "$SPEC" ]; then SPEC="$1"; shift; else die "unexpected argument '$1'"; fi ;;
    esac
done
[ $# -eq 0 ] || { [ -z "$SPEC" ] && SPEC="$1"; }
[ -n "$SPEC" ] || { usage >&2; die "missing <PR-number | ref>"; }

set -- "$RIG/pr-reviewer" pr-review --formula \
    --var "head_ref=$SPEC" --var "base_ref=$BASE" \
    --title "pr-review: $SPEC" --json

if [ "$DRYRUN" = "yes" ]; then
    printf 'DRY RUN — would run (rig=%s):\n  %s --rig %s sling' "$RIG" "$GC" "$RIG"
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
    exit 0
fi

printf '%s\n' "review: slinging pr-review for '$SPEC' in rig '$RIG'" >&2
exec "$GC" --city "$CITY" --rig "$RIG" sling "$@"
