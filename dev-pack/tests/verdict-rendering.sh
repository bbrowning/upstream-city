#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RENDER="$ROOT/dev-pack/assets/scripts/render-verdict.sh"
FIXTURES="$ROOT/dev-pack/tests/fixtures"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { printf '%s' "$1" | grep -Fq -- "$2" || fail "$3: missing '$2'"; }

for mode in brief full; do
  args=(); [ "$mode" = full ] || args+=(--brief)
  out=$("$RENDER" "$FIXTURES/quorum-dynamic-check.json" "${args[@]}")
  assert_contains "$out" \
    'Dynamic verification: reviewer-a skipped (2 checks) · reviewer-b could_not_verify (2 checks)' \
    "quorum dynamic check $mode"
done

brief=$("$RENDER" "$FIXTURES/quorum-dynamic-request.json" --brief)
assert_contains "$brief" 'suggested dynamic verification available (see --full)' \
  'quorum dynamic request brief'

full=$("$RENDER" "$FIXTURES/quorum-dynamic-request.json" --rig paude-proxy)
assert_contains "$full" 'Suggested bounded dynamic verification plans (need your approval):' \
  'quorum dynamic request full'
assert_contains "$full" 'lane reviewer-a · 2 checks' 'quorum checks request'
assert_contains "$full" 'lane reviewer-b · 1 check' 'quorum axes request'
[ "$(printf '%s' "$full" | grep -Fc 'gc sling paude-proxy/pr-runner pr-review-dynamic')" -eq 2 ] \
  || fail 'quorum dynamic request did not render one approval per lane'
assert_contains "$full" \
  'plan_json='\''{"checks":[{"axis":"integration","purpose":"coverage","command":["python","-m","pytest","tests/test_proxy.py","-q"]}]}'\''' \
  'quorum axes request was not normalized to an executable bounded plan'

# Solo review objects retain their established status and approval shapes.
solo_check='{"head_ref":"123","verdict":"approve","findings":[],"dynamic_check":{"outcome":"pass","checks":[{},{}],"rc":0},"dynamic_request":null}'
for mode in brief full; do
  args=(); [ "$mode" = full ] || args+=(--brief)
  out=$(printf '%s' "$solo_check" | "$RENDER" - "${args[@]}")
  assert_contains "$out" 'Dynamic verification: pass (2 checks) (rc=0)' "solo dynamic check $mode"
done
solo_request='{"head_ref":"123","verdict":"approve","findings":[],"dynamic_check":null,"dynamic_request":{"checks":[{"axis":"parser","purpose":"coverage","command":["python","-m","pytest"]}]}}'
out=$(printf '%s' "$solo_request" | "$RENDER" - --rig vllm)
assert_contains "$out" 'Suggested dynamic verification plan (needs your approval):' 'solo dynamic request'
assert_contains "$out" 'gc sling vllm/pr-runner pr-review-dynamic' 'solo dynamic approval'

# A direct pr-review-dynamic.v1 verdict is not mistaken for an embedded result.
direct='{"schema":"pr-review-dynamic.v1","head_ref":"123","outcome":"pass","rc":0,"ceiling_posture":"limited","plan":{"checks":[{"axis":"parser","purpose":"coverage","command":["python","-m","pytest"]}]},"checks":[{"axis":"parser","purpose":"coverage","outcome":"pass"}],"summary":"The approved check passed."}'
for mode in brief full; do
  args=(); [ "$mode" = full ] || args+=(--brief)
  out=$(printf '%s' "$direct" | "$RENDER" - "${args[@]}")
  assert_contains "$out" 'dynamic verification pass · rc=0 · 123' "direct dynamic $mode"
  assert_contains "$out" 'coverage · parser · pass' "direct dynamic checks $mode"
done

printf 'verdict rendering: ok\n'
