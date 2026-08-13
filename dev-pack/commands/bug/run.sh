#!/usr/bin/env bash
# bug — launch a bug run without hand-typing agent targets.
#
#   gc dev-pack bug <arc-bead> [options]
#
# N = the opinion count (the fan-out dial). --n 1 (default) runs a single lane
# (hard-bug-round-solo: solo diagnosis + keystone self-verify); --n 2 runs two lanes
# that act as each other's second opinion (hard-bug-round + the correlated-convergence
# gate). Resolves the RIG (explicit --rig wins, else inferred from the bead prefix, e.g.
# vllm-123 -> vllm), then slings the round formula to <rig>/bug-coordinator with the
# <rig>/bug-worker-* lane targets filled in — so it can't rig-mismatch and you never
# type targets. The bead must live in that rig, and the pack must be attached to it
# (includes = ["dev-pack"] + `gc reload`).
#
# Env (provided by gc): GC_CITY_PATH, GC_BIN.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"

BEAD="" ; RIG="" ; LOOP="false" ; MAXR="3" ; BASEREF="origin/main"
N="1" ; MODELS=""
LANE_A_MODEL="" ; LANE_B_MODEL="" ; LANE_A_TARGET="" ; LANE_B_TARGET=""
BRANCH_PREFIX=""
DRYRUN="no"

usage() {
    cat <<'EOF'
usage: gc dev-pack bug <arc-bead> [options]

Resolve the rig (--rig, else inferred from the bead prefix) and sling the round
formula (N=1 -> hard-bug-round-solo, N=2 -> hard-bug-round) to <rig>/bug-coordinator
with the <rig>/bug-worker-* lane targets filled in.

  --rig NAME          run in this rig (default: infer from the bead prefix)
  --n N               opinion count / fan-out: 1 (solo, default) or 2 (two lanes)
  --models M[,M]      per-run models, positional to the lanes (e.g. opus,sonnet);
                      empty entries defer to each agent's city.toml option_defaults
  --loop              drive the full convergence loop (default OFF = Stage-1 report-only)
  --max-rounds N      per-phase iteration cap (default 3)
  --base-ref REF      baseline ref the lanes read against (default origin/main)
  --lane-a-model M    pin lane A's model (overrides --models; default -> option_defaults)
  --lane-b-model M    pin lane B's model (overrides --models; N=2 only)
  --lane-a-target T   override lane A target (default <rig>/bug-worker-a)
  --lane-b-target T   override lane B target (default <rig>/bug-worker-b; N=2 only)
  --branch-prefix P   prefix the eventual fix branch (default: unset -> no prefix)
  --dry-run           print the gc sling command without running it (skips live checks)
  -h, --help
EOF
}
die() { printf '%s\n' "bug: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)             RIG="${2:?}"; shift 2 ;;
        --rig=*)           RIG="${1#*=}"; shift ;;
        --n)               N="${2:?}"; shift 2 ;;
        --n=*)             N="${1#*=}"; shift ;;
        --models)          MODELS="${2:?}"; shift 2 ;;
        --models=*)        MODELS="${1#*=}"; shift ;;
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
        --branch-prefix)   BRANCH_PREFIX="${2:?}"; shift 2 ;;
        --branch-prefix=*) BRANCH_PREFIX="${1#*=}"; shift ;;
        --dry-run)         DRYRUN="yes"; shift ;;
        -h|--help)         usage; exit 0 ;;
        --)                shift; break ;;
        -*)                die "unknown option '$1'" ;;
        *)                 if [ -z "$BEAD" ]; then BEAD="$1"; shift; else die "unexpected argument '$1'"; fi ;;
    esac
done
[ $# -eq 0 ] || { [ -z "$BEAD" ] && BEAD="$1"; }
[ -n "$BEAD" ] || { usage >&2; die "missing <arc-bead>"; }

# Only two lane-steps exist today, so N is 1 or 2 (the structure extends to N>2 by
# adding lane-count formula variants).
case "$N" in
    1|2) ;;
    *) die "--n must be 1 or 2 (got '$N')" ;;
esac

# Resolve per-lane models: explicit --lane-X-model wins; else positional from --models.
if [ -n "$MODELS" ]; then
    IFS=',' read -r M1 M2 _ <<<"$MODELS" || true
    [ -n "$LANE_A_MODEL" ] || LANE_A_MODEL="${M1:-}"
    [ -n "$LANE_B_MODEL" ] || LANE_B_MODEL="${M2:-}"
fi

# Resolve the rig: explicit --rig wins; else infer from the bead prefix (<rig>-<n>).
if [ -z "$RIG" ]; then
    RIG="${BEAD%-*}"
    [ -n "$RIG" ] && [ "$RIG" != "$BEAD" ] || die "cannot infer rig from bead '$BEAD'; pass --rig NAME"
fi

COORD="$RIG/bug-coordinator"
[ -n "$LANE_A_TARGET" ] || LANE_A_TARGET="$RIG/bug-worker-a"
[ -n "$LANE_B_TARGET" ] || LANE_B_TARGET="$RIG/bug-worker-b"

# Pick the formula by opinion count.
if [ "$N" = "1" ]; then
    FORMULA="hard-bug-round-solo"
    if [ -n "$LANE_B_MODEL" ] || [ "$LANE_B_TARGET" != "$RIG/bug-worker-b" ]; then
        printf '%s\n' "bug: WARN N=1 ignores lane-B options (no second lane)" >&2
    fi
else
    FORMULA="hard-bug-round"
fi

# Live sanity checks (skipped under --dry-run so it stays a pure preview).
if [ "$DRYRUN" != "yes" ]; then
    "$GC" --city "$CITY" --rig "$RIG" bd show "$BEAD" --json >/dev/null 2>&1 \
        || die "bead '$BEAD' not found in rig '$RIG' (wrong --rig, or create it there first)"
    if ! "$GC" --city "$CITY" agent list 2>/dev/null | grep -q "$COORD"; then
        printf '%s\n' "bug: WARN '$COORD' not found — is dev-pack in rig '$RIG' includes, and has 'gc reload' run?" >&2
    fi
fi

set -- "$COORD" "$FORMULA" --formula \
    --var "bug_bead=$BEAD" --var "phase=root_cause" --var "round=1" \
    --var "max_rounds=$MAXR" --var "enable_loop=$LOOP" --var "base_ref=$BASEREF" \
    --var "lane_a_target=$LANE_A_TARGET" \
    --var "coordinator_target=$COORD"
# Lane B exists only at N=2.
if [ "$N" = "2" ]; then set -- "$@" --var "lane_b_target=$LANE_B_TARGET"; fi
# Pin a lane's model only when explicitly set; empty defers to the agent's
# city.toml option_defaults (provider/agent/rig-patch). Use `if` (not `&&`) so a
# false test doesn't trip `set -e`.
if [ -n "$LANE_A_MODEL" ]; then set -- "$@" --var "lane_a_model=$LANE_A_MODEL"; fi
if [ "$N" = "2" ] && [ -n "$LANE_B_MODEL" ]; then set -- "$@" --var "lane_b_model=$LANE_B_MODEL"; fi
# branch_prefix defaults to "" in the formula too, but only pass it explicitly
# when set so a --dry-run without it matches the formula's own default output.
if [ -n "$BRANCH_PREFIX" ]; then set -- "$@" --var "branch_prefix=$BRANCH_PREFIX"; fi
set -- "$@" --title "bug root-cause round 1: $BEAD" --json

if [ "$DRYRUN" = "yes" ]; then
    printf 'DRY RUN — would run (rig=%s, n=%s, loop=%s):\n  %s --rig %s sling' "$RIG" "$N" "$LOOP" "$GC" "$RIG"
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
    exit 0
fi

printf '%s\n' "bug: launching bug (N=$N) on $BEAD in rig '$RIG' (loop=$LOOP, max_rounds=$MAXR)" >&2
exec "$GC" --city "$CITY" --rig "$RIG" sling "$@"
