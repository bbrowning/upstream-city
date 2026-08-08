#!/usr/bin/env bash
# start — launch a hard-bug run without hand-typing agent targets.
#
#   gc hard-bug-pack start <arc-bead> [options]
#
# Resolves the RIG (explicit --rig wins, else inferred from the bead prefix, e.g.
# vllm-123 -> vllm), then slings hard-bug-round to <rig>/hb-coordinator with the
# <rig>/hb-worker-a|worker-b lane targets filled in — so it can't rig-mismatch and you
# never type targets. The bead must live in that rig, and the pack must be attached
# to it (includes = ["hard-bug-pack"] + `gc reload`).
#
# Env (provided by gc): GC_CITY_PATH, GC_BIN.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"

BEAD="" ; RIG="" ; LOOP="false" ; MAXR="3" ; BASEREF="origin/main"
LANE_A_MODEL="" ; LANE_B_MODEL="" ; LANE_A_TARGET="" ; LANE_B_TARGET=""
DRYRUN="no"

usage() {
    cat <<'EOF'
usage: gc hard-bug-pack start <arc-bead> [options]

Resolve the rig (--rig, else inferred from the bead prefix) and sling
hard-bug-round to <rig>/hb-coordinator with the <rig>/worker-* lane targets filled in.

  --rig NAME          run in this rig (default: infer from the bead prefix)
  --loop              drive the full convergence loop (default OFF = Stage-1 report-only)
  --max-rounds N      per-phase iteration cap (default 3)
  --base-ref REF      baseline ref the lanes read against (default origin/main)
  --lane-a-model M    pin lane A's model this run (default: unset -> city.toml option_defaults)
  --lane-b-model M    pin lane B's model this run (default: unset -> city.toml option_defaults)
  --lane-a-target T   override lane A target (default <rig>/hb-worker-a)
  --lane-b-target T   override lane B target (default <rig>/hb-worker-b)
  --dry-run           print the gc sling command without running it (skips live checks)
  -h, --help
EOF
}
die() { printf '%s\n' "start: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)             RIG="${2:?}"; shift 2 ;;
        --rig=*)           RIG="${1#*=}"; shift ;;
        --loop)            LOOP="true"; shift ;;
        --max-rounds)      MAXR="${2:?}"; shift 2 ;;
        --max-rounds=*)    MAXR="${1#*=}"; shift ;;
        --base-ref)        BASEREF="${2:?}"; shift 2 ;;
        --base-ref=*)      BASEREF="${1#*=}"; shift ;;
        --lane-a-model)    LANE_A_MODEL="${2:?}"; shift 2 ;;
        --lane-a-model=*)  LANE_A_MODEL="${1#*=}"; shift ;;
        --lane-b-model)    LANE_B_MODEL="${2:?}"; shift 2 ;;
        --lane-b-model=*)  LANE_B_MODEL="${1#*=}"; shift ;;
        --lane-a-target)   LANE_A_TARGET="${2:?}"; shift 2 ;;
        --lane-a-target=*) LANE_A_TARGET="${1#*=}"; shift ;;
        --lane-b-target)   LANE_B_TARGET="${2:?}"; shift 2 ;;
        --lane-b-target=*) LANE_B_TARGET="${1#*=}"; shift ;;
        --dry-run)         DRYRUN="yes"; shift ;;
        -h|--help)         usage; exit 0 ;;
        --)                shift; break ;;
        -*)                die "unknown option '$1'" ;;
        *)                 if [ -z "$BEAD" ]; then BEAD="$1"; shift; else die "unexpected argument '$1'"; fi ;;
    esac
done
[ $# -eq 0 ] || { [ -z "$BEAD" ] && BEAD="$1"; }
[ -n "$BEAD" ] || { usage >&2; die "missing <arc-bead>"; }

# Resolve the rig: explicit --rig wins; else infer from the bead prefix (<rig>-<n>).
if [ -z "$RIG" ]; then
    RIG="${BEAD%-*}"
    [ -n "$RIG" ] && [ "$RIG" != "$BEAD" ] || die "cannot infer rig from bead '$BEAD'; pass --rig NAME"
fi

COORD="$RIG/hb-coordinator"
[ -n "$LANE_A_TARGET" ] || LANE_A_TARGET="$RIG/hb-worker-a"
[ -n "$LANE_B_TARGET" ] || LANE_B_TARGET="$RIG/hb-worker-b"

# Live sanity checks (skipped under --dry-run so it stays a pure preview).
if [ "$DRYRUN" != "yes" ]; then
    "$GC" --city "$CITY" --rig "$RIG" bd show "$BEAD" --json >/dev/null 2>&1 \
        || die "bead '$BEAD' not found in rig '$RIG' (wrong --rig, or create it there first)"
    if ! "$GC" --city "$CITY" agent list 2>/dev/null | grep -q "$COORD"; then
        printf '%s\n' "start: WARN '$COORD' not found — is hard-bug-pack in rig '$RIG' includes, and has 'gc reload' run?" >&2
    fi
fi

set -- "$COORD" hard-bug-round --formula \
    --var "bug_bead=$BEAD" --var "phase=root_cause" --var "round=1" \
    --var "max_rounds=$MAXR" --var "enable_loop=$LOOP" --var "base_ref=$BASEREF" \
    --var "lane_a_target=$LANE_A_TARGET" \
    --var "lane_b_target=$LANE_B_TARGET" \
    --var "coordinator_target=$COORD"
# Pin a lane's model only when explicitly set; empty defers to the agent's
# city.toml option_defaults (provider/agent/rig-patch). Use `if` (not `&&`) so a
# false test doesn't trip `set -e`.
if [ -n "$LANE_A_MODEL" ]; then set -- "$@" --var "lane_a_model=$LANE_A_MODEL"; fi
if [ -n "$LANE_B_MODEL" ]; then set -- "$@" --var "lane_b_model=$LANE_B_MODEL"; fi
set -- "$@" --title "hard-bug root-cause round 1: $BEAD" --json

if [ "$DRYRUN" = "yes" ]; then
    printf 'DRY RUN — would run (rig=%s, loop=%s):\n  %s --rig %s sling' "$RIG" "$LOOP" "$GC" "$RIG"
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
    exit 0
fi

printf '%s\n' "start: launching hard-bug on $BEAD in rig '$RIG' (loop=$LOOP, max_rounds=$MAXR)" >&2
exec "$GC" --city "$CITY" --rig "$RIG" sling "$@"
