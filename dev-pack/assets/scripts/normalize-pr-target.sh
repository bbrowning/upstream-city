#!/usr/bin/env bash
# Normalize a dev-pack target at a command/handoff boundary.
#
# A valid <rig>#<PR> token is an alias for the bare numeric PR plus --rig <rig>.
# Any token containing '#' is reserved for this alias and must match it exactly;
# this keeps malformed aliases and shell metacharacters out of workflow text and
# git fetch/diff arguments. Other tokens (bead ids and ordinary git refs) pass
# through unchanged.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
SPEC=""
RIG="vllm"
RIG_EXPLICIT=0

die() { printf '%s\n' "normalize-pr-target: $*" >&2; exit 2; }
usage() {
    printf '%s\n' \
        "usage: normalize-pr-target.sh <PR | rig#PR | ref | bead> [--rig NAME] [--rig-explicit]" \
        "prints {spec,rig,is_pr,was_alias} as JSON"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)          RIG="${2:?--rig needs a value}"; shift 2 ;;
        --rig=*)        RIG="${1#*=}"; shift ;;
        --rig-explicit) RIG_EXPLICIT=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        --)             shift; break ;;
        -*)             die "unknown option '$1'" ;;
        *)              if [ -z "$SPEC" ]; then SPEC="$1"; shift
                        else die "unexpected argument '$1'"; fi ;;
    esac
done
[ $# -eq 0 ] || { [ -z "$SPEC" ] && SPEC="$1"; }
[ -n "$SPEC" ] || die "missing target"

WAS_ALIAS=false
if [[ "$SPEC" == *'#'* ]]; then
    if [[ "$SPEC" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*)#([0-9]+)$ ]]; then
        ALIAS_RIG="${BASH_REMATCH[1]}"
        ALIAS_PR="${BASH_REMATCH[2]}"
    else
        die "malformed rig#PR target '$SPEC' (expected <rig>#<numeric-PR>)"
    fi
    if [ "$RIG_EXPLICIT" -eq 1 ] && [ "$RIG" != "$ALIAS_RIG" ]; then
        die "target '$SPEC' conflicts with --rig '$RIG'"
    fi
    RIG="$ALIAS_RIG"
    SPEC="$ALIAS_PR"
    WAS_ALIAS=true
fi

# Validate here, before a command can sling work or use a target in git.
RIGS_JSON=$("$GC" --city "$CITY" rig list --json 2>/dev/null) \
    || die "could not list rigs for city '$CITY'"
printf '%s' "$RIGS_JSON" | jq -e --arg rig "$RIG" \
    '.rigs[]? | select(.name == $rig)' >/dev/null 2>&1 \
    || die "unknown rig '$RIG'"

if [[ "$SPEC" =~ ^[0-9]+$ ]]; then IS_PR=true; else IS_PR=false; fi
jq -cn --arg spec "$SPEC" --arg rig "$RIG" \
    --argjson is_pr "$IS_PR" --argjson was_alias "$WAS_ALIAS" \
    '{spec:$spec, rig:$rig, is_pr:$is_pr, was_alias:$was_alias}'
