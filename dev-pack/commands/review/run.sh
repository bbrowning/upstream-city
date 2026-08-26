#!/usr/bin/env bash
# review — kick off a posture-gated PR review without hand-typing the sling.
#
#   gc dev-pack review <PR-number | rig#PR | ref> [options]
#
# The opinion count N is the fan-out dial. --n 1 (default) slings the pr-review formula
# (triage -> single posture-gated read-only review). --n 2 slings pr-review-quorum
# (triage -> two independent reviewer lanes -> a synthesis step that takes the strictest
# merge call). The verdict lands in the human inbox (`gc mail check`) and can be
# re-rendered later with `gc dev-pack summary <bead|PR>`.
#
# --lanes selects which reviewer PROFILE(s) run the review, by name. A profile is a
# single-slot reviewer agent with a model/effort pinned via its city.toml option_defaults
# (the reliable launch path — gascity does NOT apply a per-run opt_model at launch,
# wo-au65.7). The number of profiles you name is N. So one run can compare two models by
# naming two profiles. Discover profiles with `gc agent list | grep pr-reviewer-`.
#
# Env (provided by gc): GC_CITY_PATH, GC_BIN.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZE="$SCRIPT_DIR/../../assets/scripts/normalize-pr-target.sh"
RESOLVE_LOCAL="$SCRIPT_DIR/../../assets/scripts/resolve-local-change.sh"

RIG="vllm" ; BASE="origin/main" ; SPEC="" ; ARTIFACT="" ; DRYRUN="no"
RIG_EXPLICIT=0
N="" ; LANES=""
# Default solo profile and quorum lanes when --lanes is not given (must be existing profiles).
DEFAULT_SOLO_LANE="pr-reviewer-gpt56luna-xhigh"
DEFAULT_LANE_A="pr-reviewer-sonnet-xhigh" ; DEFAULT_LANE_B="pr-reviewer-gpt56luna-xhigh"

usage() {
    cat <<'EOF'
usage: gc dev-pack review <PR-number | rig#PR | local-ref | artifact-bead> [options]

Sling the review formula (N=1 -> pr-review, N=2 -> pr-review-quorum) to <rig>/pr-review-synthesizer.

  --rig NAME       rig the PR belongs to            (default: vllm)
  --base REF       baseline the diff is against      (default: origin/main)
  --artifact X     local-change.v1 JSON file or implementation-output bead.
                   Validates repository identity, immutable commits, and that
                   the recorded local branch still points at the recorded HEAD.
  --n N            opinion count / fan-out: 1 (single reviewer, default) or 2 (quorum).
                   Cross-checked against --lanes when both are given.
  --lanes A[,B]    reviewer PROFILE(s) to run, by name; the count IS N (1 or 2). Each
                   name resolves to an agent: '<name>' or the short 'pr-reviewer-<name>'.
                   A profile pins a model+effort via its city.toml option_defaults, so
                   naming two profiles compares two models in one run. Unknown names
                   fail loudly (with the available list).
                   examples:
                     --lanes opus46-xhigh,opus48-xhigh     # compare opus 4.6 vs 4.8
                     --lanes opus46-xhigh                  # N=1 solo on the 4.6 profile
                   (no --lanes: --n 1 -> gpt56luna-xhigh; --n 2 -> the two default
                   profiles sonnet-xhigh + gpt56luna-xhigh.)
  --dry-run        validate + print the gc sling command without running it
  -h, --help

Add a profile (new model/effort combo): create dev-pack/agents/pr-reviewer-<name>/
(copy an existing one) + a [[rigs.patches]] in city.toml pinning option_defaults, then
`gc reload`. Custom claude ids (e.g. claude-opus-4-6) must first be registered in
city.toml under [providers.claude] via options_schema_merge="by_key".
EOF
}
die() { printf '%s\n' "review: $*" >&2; exit 2; }

# --- agent lookup (cached) ---------------------------------------------------
AGENTS_CACHE=""
load_agents() { [ -n "$AGENTS_CACHE" ] || AGENTS_CACHE="$("$GC" --city "$CITY" agent list 2>/dev/null | awk '{print $1}')"; }
agent_exists() { load_agents; printf '%s\n' "$AGENTS_CACHE" | grep -qx "$1"; }
available_profiles() { load_agents; printf '%s\n' "$AGENTS_CACHE" | grep -E "^$RIG/pr-reviewer-" | sed "s#^$RIG/##" | paste -sd',' - | sed 's/,/, /g'; }
RESOLVED=""
resolve_lane() {  # $1=name -> sets RESOLVED to a rig-qualified agent, or dies
    local e="$1" cand
    for cand in "$RIG/$e" "$RIG/pr-reviewer-$e"; do
        if agent_exists "$cand"; then RESOLVED="$cand"; return 0; fi
    done
    die "unknown lane profile '$e'. Available: $(available_profiles). (Add one: dev-pack/agents/pr-reviewer-<name>/ + a city.toml patch, then gc reload.)"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)       RIG="${2:?}"; RIG_EXPLICIT=1; shift 2 ;;
        --rig=*)     RIG="${1#*=}"; RIG_EXPLICIT=1; shift ;;
        --base)      BASE="${2:?}"; shift 2 ;;
        --base=*)    BASE="${1#*=}"; shift ;;
        --artifact)  ARTIFACT="${2:?}"; shift 2 ;;
        --artifact=*) ARTIFACT="${1#*=}"; shift ;;
        --n)         N="${2:?}"; shift 2 ;;
        --n=*)       N="${1#*=}"; shift ;;
        --lanes)     LANES="${2:?}"; shift 2 ;;
        --lanes=*)   LANES="${1#*=}"; shift ;;
        --dry-run)   DRYRUN="yes"; shift ;;
        -h|--help)   usage; exit 0 ;;
        --)          shift; break ;;
        -*)          die "unknown option '$1'" ;;
        *)           if [ -z "$SPEC" ]; then SPEC="$1"; shift; else die "unexpected argument '$1'"; fi ;;
    esac
done
[ $# -eq 0 ] || { [ -z "$SPEC" ] && SPEC="$1"; }
[ -z "$ARTIFACT" ] || [ -z "$SPEC" ] || die "do not combine a positional target with --artifact"
[ -n "$SPEC$ARTIFACT" ] || { usage >&2; die "missing review target"; }
[ -n "$SPEC" ] || SPEC="$ARTIFACT"
[ -x "$NORMALIZE" ] || die "target normalizer not found/executable: $NORMALIZE"
NORM_ARGS=(--rig "$RIG")
[ "$RIG_EXPLICIT" -eq 1 ] && NORM_ARGS+=(--rig-explicit)
NORM=$("$NORMALIZE" "$SPEC" "${NORM_ARGS[@]}") || exit $?
SPEC=$(printf '%s' "$NORM" | jq -r '.spec')
RIG=$(printf '%s' "$NORM" | jq -r '.rig')

# Resolve implementation handoffs before dispatch. Reviewers receive immutable
# SHAs plus provenance and independently re-run the same branch/repository guard.
[ -x "$RESOLVE_LOCAL" ] || die "local-change resolver not found/executable: $RESOLVE_LOCAL"
RIGS_JSON=$("$GC" --city "$CITY" rig list --json 2>/dev/null) || die "could not list rigs"
RIG_PATH=$(printf '%s' "$RIGS_JSON" | jq -er --arg rig "$RIG" '.rigs[] | select(.name == $rig) | .path') \
    || die "could not resolve repository path for rig '$RIG'"
LOCAL_JSON="" ; DISPLAY_SPEC="$SPEC"
if [ -n "$ARTIFACT" ]; then
    [ ! -f "$ARTIFACT" ] || ARTIFACT=$(realpath "$ARTIFACT")
    DISPLAY_SPEC="$ARTIFACT"
    LOCAL_JSON=$("$RESOLVE_LOCAL" --repo "$RIG_PATH" --rig "$RIG" --artifact "$ARTIFACT") || exit $?
elif git -C "$RIG_PATH" rev-parse --verify "$SPEC^{commit}" >/dev/null 2>&1; then
    LOCAL_JSON=$("$RESOLVE_LOCAL" --repo "$RIG_PATH" --rig "$RIG" --head "$SPEC" --base "$BASE") || exit $?
elif [[ "$SPEC" == "$RIG-"* ]]; then
    # A rig-prefixed non-ref is the positional artifact-bead form. Use
    # --artifact for cross-rig checks or file paths so intent is unambiguous.
    LOCAL_JSON=$("$RESOLVE_LOCAL" --repo "$RIG_PATH" --rig "$RIG" --artifact "$SPEC") || exit $?
fi

LOCAL_ARTIFACT_ID="" ; LOCAL_ARTIFACT_REF="" ; LOCAL_REPOSITORY_ID="" ; LOCAL_BRANCH="" ; LOCAL_REVISION=""
LOCAL_BASE_SHA="" ; LOCAL_HEAD_SHA=""
if [ -n "$LOCAL_JSON" ]; then
    LOCAL_ARTIFACT_ID=$(printf '%s' "$LOCAL_JSON" | jq -r '.artifact_id')
    if [ -n "$ARTIFACT" ]; then LOCAL_ARTIFACT_REF="$ARTIFACT"; else LOCAL_ARTIFACT_REF="$DISPLAY_SPEC"; fi
    LOCAL_REPOSITORY_ID=$(printf '%s' "$LOCAL_JSON" | jq -r '.repository.id')
    LOCAL_BRANCH=$(printf '%s' "$LOCAL_JSON" | jq -r '.head.branch')
    LOCAL_REVISION=$(printf '%s' "$LOCAL_JSON" | jq -r '.revision.number')
    LOCAL_BASE_SHA=$(printf '%s' "$LOCAL_JSON" | jq -r '.base.sha')
    LOCAL_HEAD_SHA=$(printf '%s' "$LOCAL_JSON" | jq -r '.head.sha')
    BASE="$LOCAL_BASE_SHA"
    SPEC="$LOCAL_HEAD_SHA"
fi

# --- resolve N + lane targets from --lanes -----------------------------------
declare -a LT   # resolved rig-qualified lane targets
if [ -n "$LANES" ]; then
    IFS=',' read -r -a LE <<<"$LANES" || true
    LN=${#LE[@]}
    if [ -n "$N" ] && [ "$N" != "$LN" ]; then
        die "--n ($N) disagrees with --lanes count ($LN); omit --n or make them match"
    fi
    N="$LN"
    i=0; for e in "${LE[@]}"; do resolve_lane "$e"; LT[$i]="$RESOLVED"; i=$((i + 1)); done
else
    [ -n "$N" ] || N=1
fi

# Only two reviewer lane-steps exist today, so N is 1 or 2.
case "$N" in
    1|2) ;;
    *) die "N must be 1 or 2 (got '$N'); N>2 is not supported yet (formula generalization is tracked as bead wo-au65.1)" ;;
esac

# --- build the sling argv -----------------------------------------------------
if [ "$N" = "1" ]; then
    # Solo review. Route to a model-pinned profile so the provider/model/effort are
    # applied reliably at launch (gas city does not apply opt_model at dispatch).
    if [ -n "$LANES" ]; then RTARGET="${LT[0]}"; else
        RTARGET="$RIG/$DEFAULT_SOLO_LANE"
        agent_exists "$RTARGET" || die "default solo lane '$RTARGET' not found — run 'gc reload'? Or pass --lanes A (available: $(available_profiles))."
    fi
    set -- "$RIG/pr-review-synthesizer" pr-review --formula \
        --var "head_ref=$SPEC" --var "base_ref=$BASE" \
        --var "implementation_artifact_ref=$LOCAL_ARTIFACT_REF" \
        --var "implementation_artifact_id=$LOCAL_ARTIFACT_ID" \
        --var "implementation_repository_id=$LOCAL_REPOSITORY_ID" \
        --var "implementation_branch=$LOCAL_BRANCH" --var "implementation_revision=$LOCAL_REVISION" \
        --var "review_target=$RTARGET" \
        --title "pr-review: $DISPLAY_SPEC" --json
else
    # Quorum. Named profiles pick the two lanes; otherwise the two default profiles.
    if [ -n "$LANES" ]; then AT="${LT[0]}"; BT="${LT[1]}"; else
        AT="$RIG/$DEFAULT_LANE_A" ; BT="$RIG/$DEFAULT_LANE_B"
        agent_exists "$AT" || die "default lane '$AT' not found — run 'gc reload'? Or pass --lanes A,B (available: $(available_profiles))."
        agent_exists "$BT" || die "default lane '$BT' not found — run 'gc reload'? Or pass --lanes A,B (available: $(available_profiles))."
    fi
    set -- "$RIG/pr-review-synthesizer" pr-review-quorum --formula \
        --var "head_ref=$SPEC" --var "base_ref=$BASE" \
        --var "implementation_artifact_ref=$LOCAL_ARTIFACT_REF" \
        --var "implementation_artifact_id=$LOCAL_ARTIFACT_ID" \
        --var "implementation_repository_id=$LOCAL_REPOSITORY_ID" \
        --var "implementation_branch=$LOCAL_BRANCH" --var "implementation_revision=$LOCAL_REVISION" \
        --var "triage_target=$RIG/pr-triage" \
        --var "lane_a_target=$AT" \
        --var "lane_b_target=$BT" \
        --var "synthesis_target=$RIG/pr-review-synthesizer" \
        --title "pr-review-quorum: $DISPLAY_SPEC" --json
fi

if [ "$DRYRUN" = "yes" ]; then
    printf 'DRY RUN — would run (rig=%s, n=%s):\n  %s --rig %s sling' "$RIG" "$N" "$GC" "$RIG"
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
    exit 0
fi

printf '%s\n' "review: slinging review (N=$N) for '$SPEC' in rig '$RIG'" >&2
exec "$GC" --city "$CITY" --rig "$RIG" sling "$@"
