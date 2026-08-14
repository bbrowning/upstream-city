#!/usr/bin/env bash
# review — kick off a posture-gated PR review without hand-typing the sling.
#
#   gc dev-pack review <PR-number | ref> [options]
#
# The opinion count N is the fan-out dial. --n 1 (default) slings the pr-review formula
# (triage -> single posture-gated read-only review). --n 2 slings pr-review-quorum
# (triage -> two independent reviewer lanes -> a synthesis step that takes the strictest
# merge call). The verdict lands in the human inbox (`gc mail check`) and can be
# re-rendered later with `gc dev-pack summary <bead|PR>`.
#
# --lineup names the provider/model/effort PER OPINION on the command line, so one run
# can compare two configurations (e.g. opus-4-6 vs opus, or two effort levels). The
# entry COUNT sets N. Any field left blank defers to that agent's city.toml
# option_defaults. Every named value is validated against the RUNNING binary's real
# schema BEFORE slinging (see assets/scripts/lineup-options.sh) — gascity silently drops
# an unknown model on the launch path, so we fail loudly here instead.
#
# Env (provided by gc): GC_CITY_PATH, GC_BIN.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINEUP_OPTS="$SCRIPT_DIR/../../assets/scripts/lineup-options.sh"

RIG="vllm" ; BASE="origin/main" ; SPEC="" ; DRYRUN="no"
N="" ; LINEUP=""

usage() {
    cat <<'EOF'
usage: gc dev-pack review <PR-number | ref> [options]

Sling the review formula (N=1 -> pr-review, N=2 -> pr-review-quorum) to <rig>/pr-reviewer.

  --rig NAME       rig the PR belongs to            (default: vllm)
  --base REF       baseline the diff is against      (default: origin/main)
  --n N            opinion count / fan-out: 1 (single reviewer, default) or 2 (quorum).
                   Ignored/cross-checked when --lineup is given (its entry count sets N).
  --lineup SPEC    per-opinion 'provider:model:effort' entries, comma-separated; the
                   entry count IS N (1 or 2). Any field may be blank -> defers to the
                   agent's city.toml option_defaults. Every value is validated up front.
                     provider : claude   (codex needs a one-time setup — see README)
                     model    : a valid slug OR a full id declared in city.toml, e.g.
                                opus | opus-4-7 | sonnet | sonnet-5 | sonnet-4-6 |
                                haiku | fable-5 | claude-opus-4-6   (NB: no bare opus-4-6)
                     effort   : low | medium | high | xhigh | max
                   examples:
                     --lineup 'claude:opus:xhigh,claude:sonnet:high'   # 2-way compare
                     --lineup 'claude:claude-opus-4-6:high,claude:opus:high'
                     --lineup 'claude::max'                            # N=1, default model, max effort
  --dry-run        validate + print the gc sling command without running it
  -h, --help

Custom claude models (e.g. claude-opus-4-6): declare them once in city.toml under
[providers.claude] via `options_schema_merge = "by_key"` (then `gc reload`). They then
become selectable AND validated here. See city.toml for the recipe.
EOF
}
die() { printf '%s\n' "review: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)       RIG="${2:?}"; shift 2 ;;
        --rig=*)     RIG="${1#*=}"; shift ;;
        --base)      BASE="${2:?}"; shift 2 ;;
        --base=*)    BASE="${1#*=}"; shift ;;
        --n)         N="${2:?}"; shift 2 ;;
        --n=*)       N="${1#*=}"; shift ;;
        --lineup)    LINEUP="${2:?}"; shift 2 ;;
        --lineup=*)  LINEUP="${1#*=}"; shift ;;
        --dry-run)   DRYRUN="yes"; shift ;;
        -h|--help)   usage; exit 0 ;;
        --)          shift; break ;;
        -*)          die "unknown option '$1'" ;;
        *)           if [ -z "$SPEC" ]; then SPEC="$1"; shift; else die "unexpected argument '$1'"; fi ;;
    esac
done
[ $# -eq 0 ] || { [ -z "$SPEC" ] && SPEC="$1"; }
[ -n "$SPEC" ] || { usage >&2; die "missing <PR-number | ref>"; }

# --- valid-option lookup + validation (memoized for one provider at a time) ---
_OPT_PROV="" ; _OPT_MODELS="" ; _OPT_EFFORTS=""
load_provider_opts() {  # $1=provider
    local p="$1" out key rest
    [ "$_OPT_PROV" = "$p" ] && return 0
    out="$(bash "$LINEUP_OPTS" "$p")" \
        || die "cannot resolve options for provider '$p' (API down AND not in the offline allowlist)"
    _OPT_MODELS="" ; _OPT_EFFORTS=""
    while IFS=' ' read -r key rest; do
        case "$key" in model) _OPT_MODELS="$rest" ;; effort) _OPT_EFFORTS="$rest" ;; esac
    done <<<"$out"
    _OPT_PROV="$p"
}
validate_provider() {  # $1=provider
    case "$1" in
        claude) : ;;
        codex)  die "provider 'codex' is not wired yet. To enable claude-vs-codex: (1) uncomment [providers.codex] in city.toml + set OPENAI_API_KEY (codex CLI on PATH); (2) add pr-reviewer-codex-a/-b agents (copy pr-reviewer-a); (3) extend this command to map provider=codex. See city.toml + dev-pack/README.md." ;;
        *)      die "unknown provider '$1' (supported: claude)" ;;
    esac
}
validate_field() {  # $1=provider $2=model|effort $3=value
    local p="$1" key="$2" val="$3" set=""
    [ -n "$val" ] || return 0    # blank -> defer to option_defaults
    load_provider_opts "$p"
    case "$key" in model) set="$_OPT_MODELS" ;; effort) set="$_OPT_EFFORTS" ;; esac
    case " $set " in
        *" $val "*) return 0 ;;
        *) die "'$val' is not a valid $p $key (valid: ${set// /, })" ;;
    esac
}

# --- resolve N + per-opinion config from --lineup -----------------------------
declare -a EP EM EE   # per-entry provider / model / effort
if [ -n "$LINEUP" ]; then
    IFS=',' read -r -a ENTRIES <<<"$LINEUP" || true
    LN=${#ENTRIES[@]}
    if [ -n "$N" ] && [ "$N" != "$LN" ]; then
        die "--n ($N) disagrees with --lineup entry count ($LN); omit --n or make them match"
    fi
    N="$LN"
    idx=0
    for entry in "${ENTRIES[@]}"; do
        IFS=':' read -r p m e _ <<<"$entry" || true
        [ -n "$p" ] || p="claude"
        validate_provider "$p"
        validate_field "$p" model "$m"
        validate_field "$p" effort "$e"
        EP[$idx]="$p"; EM[$idx]="$m"; EE[$idx]="$e"
        idx=$((idx + 1))
    done
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
    RTARGET="$RIG/pr-reviewer" ; RMODEL="" ; REFFORT=""
    if [ -n "$LINEUP" ]; then
        RMODEL="${EM[0]}" ; REFFORT="${EE[0]}"
        # A per-run model/effort override is only reliable on a single-slot agent (a warm
        # pooled pr-reviewer session isn't relaunched per bead). Route an overridden solo
        # review to pr-reviewer-a (single slot); it still notifies the human because the
        # pr-review formula does NOT stamp gc.review_quorum_lane.
        if [ -n "$RMODEL" ] || [ -n "$REFFORT" ]; then RTARGET="$RIG/pr-reviewer-a"; fi
    fi
    set -- "$RIG/pr-reviewer" pr-review --formula \
        --var "head_ref=$SPEC" --var "base_ref=$BASE" \
        --var "review_target=$RTARGET"
    if [ -n "$RMODEL" ]; then set -- "$@" --var "review_model=$RMODEL"; fi
    if [ -n "$REFFORT" ]; then set -- "$@" --var "review_effort=$REFFORT"; fi
    set -- "$@" --title "pr-review: $SPEC" --json
else
    set -- "$RIG/pr-reviewer" pr-review-quorum --formula \
        --var "head_ref=$SPEC" --var "base_ref=$BASE" \
        --var "triage_target=$RIG/pr-triage" \
        --var "lane_a_target=$RIG/pr-reviewer-a" \
        --var "lane_b_target=$RIG/pr-reviewer-b" \
        --var "synthesis_target=$RIG/pr-reviewer"
    # Pin a lane's model/effort only when explicitly set; empty defers to the agent's
    # city.toml option_defaults. `if` (not `&&`) so a false test doesn't trip `set -e`.
    if [ -n "$LINEUP" ]; then
        if [ -n "${EM[0]}" ]; then set -- "$@" --var "lane_a_model=${EM[0]}"; fi
        if [ -n "${EE[0]}" ]; then set -- "$@" --var "lane_a_effort=${EE[0]}"; fi
        if [ -n "${EM[1]}" ]; then set -- "$@" --var "lane_b_model=${EM[1]}"; fi
        if [ -n "${EE[1]}" ]; then set -- "$@" --var "lane_b_effort=${EE[1]}"; fi
    fi
    set -- "$@" --title "pr-review-quorum: $SPEC" --json
fi

if [ "$DRYRUN" = "yes" ]; then
    printf 'DRY RUN — would run (rig=%s, n=%s):\n  %s --rig %s sling' "$RIG" "$N" "$GC" "$RIG"
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
    exit 0
fi

printf '%s\n' "review: slinging review (N=$N) for '$SPEC' in rig '$RIG'" >&2
exec "$GC" --city "$CITY" --rig "$RIG" sling "$@"
