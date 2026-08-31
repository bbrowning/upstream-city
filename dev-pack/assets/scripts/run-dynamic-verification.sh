#!/usr/bin/env bash
# run-dynamic-verification.sh — bounded multi-axis dynamic verification gate.
#
# Accepts a JSON plan on stdin (or --plan-json) and delegates every command to
# run-scoped-check.sh.  The aggregate limits intentionally retain the old
# single-check worst-case envelope: at most 3 invocations, 600 seconds, and
# 65536 captured bytes total.  Two coverage checks may name distinct change
# axes; one final follow-up may decisively probe an uncovered keystone.
set -euo pipefail
set -f

HERE="$(cd "$(dirname "$0")" && pwd)"
SCOPED_GATE="$HERE/run-scoped-check.sh"
HEAD=""; BASE="origin/main"; MIN_CEILING=""; EXPECT_SHA=""
ALLOW_PREFIX="tests/"; PRESCAN=""; INTERNAL_ARTIFACT=""; PLAN_JSON=""
MAX_CHECKS=3; MAX_COVERAGE=2; TOTAL_TIMEOUT=600; TOTAL_CAP=65536

die() { printf '%s\n' "run-dynamic-verification: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --head) HEAD="${2:?}"; shift 2 ;;
        --head=*) HEAD="${1#*=}"; shift ;;
        --base) BASE="${2:?}"; shift 2 ;;
        --base=*) BASE="${1#*=}"; shift ;;
        --min-ceiling) MIN_CEILING="${2:?}"; shift 2 ;;
        --min-ceiling=*) MIN_CEILING="${1#*=}"; shift ;;
        --expect-head-sha) EXPECT_SHA="${2:?}"; shift 2 ;;
        --expect-head-sha=*) EXPECT_SHA="${1#*=}"; shift ;;
        --allow-path-prefix) ALLOW_PREFIX="${2:?}"; shift 2 ;;
        --allow-path-prefix=*) ALLOW_PREFIX="${1#*=}"; shift ;;
        --prescan) PRESCAN="${2:?}"; shift 2 ;;
        --prescan=*) PRESCAN="${1#*=}"; shift ;;
        --internal-artifact) INTERNAL_ARTIFACT="${2:?}"; shift 2 ;;
        --internal-artifact=*) INTERNAL_ARTIFACT="${1#*=}"; shift ;;
        --plan-json) PLAN_JSON="${2:?}"; shift 2 ;;
        --plan-json=*) PLAN_JSON="${1#*=}"; shift ;;
        -*) die "unknown option '$1'" ;;
        *) die "unexpected argument '$1'" ;;
    esac
done

[ -n "$HEAD" ] || die "usage: --head is required"
[ -n "$MIN_CEILING" ] || die "usage: --min-ceiling is required"
[ -x "$SCOPED_GATE" ] || die "scoped gate not found/executable: $SCOPED_GATE"
if [ -z "$PLAN_JSON" ]; then PLAN_JSON=$(cat); fi

# A plan is data, never a shell fragment. Coverage axes must be distinct; the
# optional follow-up is last and may revisit one axis to close a specific crux.
printf '%s' "$PLAN_JSON" | jq -e \
  --argjson max "$MAX_CHECKS" --argjson coverage "$MAX_COVERAGE" '
  type == "object" and (.checks | type == "array") and
  (.checks | length >= 1 and length <= $max) and
  (all(.checks[]; (.axis | type == "string" and length > 0) and
                  (.purpose == "coverage" or .purpose == "followup") and
                  (.command | type == "array" and length > 0) and
                  all(.command[]; type == "string" and length > 0))) and
  ([.checks[] | select(.purpose == "coverage")] | length >= 1 and length <= $coverage) and
  ([.checks[] | select(.purpose == "coverage") | .axis] | unique | length) ==
    ([.checks[] | select(.purpose == "coverage")] | length) and
  ([.checks[] | select(.purpose == "followup")] | length <= 1) and
  (([.checks[] | .purpose] | index("followup")) == null or .checks[-1].purpose == "followup")
' >/dev/null || die "invalid plan: require 1-2 distinct coverage axes and at most one final followup (3 checks total)"

COUNT=$(printf '%s' "$PLAN_JSON" | jq '.checks | length')
PER_TIMEOUT=$((TOTAL_TIMEOUT / COUNT))
PER_CAP=$((TOTAL_CAP / COUNT))
RESULTS='[]'; ELAPSED=0; CAP_USED=0; STOP_REASON=""; OVERALL="pass"

for ((i=0; i<COUNT; i++)); do
    case "$STOP_REASON" in worktree-mutation:*) break ;; esac
    axis=$(printf '%s' "$PLAN_JSON" | jq -r ".checks[$i].axis")
    purpose=$(printf '%s' "$PLAN_JSON" | jq -r ".checks[$i].purpose")
    if [ "$purpose" = followup ] && [ "$OVERALL" != pass ]; then
        [ -n "$STOP_REASON" ] || STOP_REASON="followup-not-run: planned coverage did not pass cleanly"
        break
    fi

    declare -a CMD=()
    while IFS= read -r encoded; do
        CMD+=("$(printf '%s' "$encoded" | base64 -d)")
    done < <(printf '%s' "$PLAN_JSON" | jq -r ".checks[$i].command[] | @base64")

    declare -a ARGS=(--head "$HEAD" --base "$BASE" --min-ceiling "$MIN_CEILING"
      --timeout "$PER_TIMEOUT" --output-cap "$PER_CAP" --allow-path-prefix "$ALLOW_PREFIX")
    [ -z "$EXPECT_SHA" ] || ARGS+=(--expect-head-sha "$EXPECT_SHA")
    [ -z "$PRESCAN" ] || ARGS+=(--prescan "$PRESCAN")
    [ -z "$INTERNAL_ARTIFACT" ] || ARGS+=(--internal-artifact "$INTERNAL_ARTIFACT")

    result=$("$SCOPED_GATE" "${ARGS[@]}" -- "${CMD[@]}") \
        || die "scoped gate failed internally for axis '$axis'"
    result=$(printf '%s' "$result" | jq -c --arg axis "$axis" --arg purpose "$purpose" \
        '. + {axis:$axis, purpose:$purpose}')
    RESULTS=$(printf '%s' "$RESULTS" | jq -c --argjson result "$result" '. + [$result]')
    duration=$(printf '%s' "$result" | jq -r '.duration_s // 0')
    bytes=$(printf '%s' "$result" | jq -r '.output_tail | length')
    ELAPSED=$((ELAPSED + duration)); CAP_USED=$((CAP_USED + bytes))
    outcome=$(printf '%s' "$result" | jq -r '.outcome')
    clean=$(printf '%s' "$result" | jq -r 'if .git_clean_after == null then true else .git_clean_after end')
    if [ "$outcome" != pass ]; then OVERALL="$outcome"; STOP_REASON="coverage-did-not-pass: $axis=$outcome"; fi
    if [ "$clean" != true ]; then OVERALL="fail"; STOP_REASON="worktree-mutation: $axis"; fi
done

RAN=$(printf '%s' "$RESULTS" | jq '[.[] | select(.ran == true)] | length')
CLEAN=$(printf '%s' "$RESULTS" | jq 'all(.[]; .git_clean_after != false)')
MUTATIONS=$(printf '%s' "$RESULTS" | jq -c '[.[].mutations_delta[]?] | unique')
AUTHORITY=$(printf '%s' "$RESULTS" | jq -r '.[0].execution_authority // "external"')
CEILING=$(printf '%s' "$RESULTS" | jq -r '.[-1].ceiling // null')
HEAD_SHA=$(printf '%s' "$RESULTS" | jq -r '.[-1].head_sha // null')

jq -n --arg schema dynamic-verification.v1 --arg outcome "$OVERALL" \
  --arg head "$HEAD" --arg base "$BASE" --arg min "$MIN_CEILING" \
  --arg authority "$AUTHORITY" --arg stop "$STOP_REASON" \
  --argjson checks "$RESULTS" --argjson elapsed "$ELAPSED" \
  --argjson cap_used "$CAP_USED" --argjson ran "$RAN" --argjson clean "$CLEAN" \
  --argjson mutations "$MUTATIONS" --arg ceiling "$CEILING" --arg head_sha "$HEAD_SHA" \
  --argjson max_checks "$MAX_CHECKS" --argjson max_coverage "$MAX_COVERAGE" \
  --argjson total_timeout "$TOTAL_TIMEOUT" --argjson total_cap "$TOTAL_CAP" '
  {schema:$schema, outcome:$outcome, head_ref:$head, base_ref:$base,
   min_ceiling:$min,
   ceiling:(if $ceiling == "null" then null else $ceiling end),
   head_sha:(if $head_sha == "null" then null else $head_sha end),
   execution_authority:$authority, ran_checks:$ran, checks:$checks,
   budget:{max_checks:$max_checks,max_coverage_axes:$max_coverage,
           max_followups:1,total_timeout_s:$total_timeout,total_output_cap_bytes:$total_cap,
           elapsed_s:$elapsed,output_bytes:$cap_used},
   git_clean_after:$clean,mutations_delta:$mutations,reason_if_stopped:$stop,
   failure_class:"none",failure_reason:""}'
