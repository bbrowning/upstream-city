#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GATE="$ROOT/dev-pack/assets/scripts/run-dynamic-verification.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

git init -q -b main "$TMP/repo"
git -C "$TMP/repo" config user.name Test
git -C "$TMP/repo" config user.email test@example.invalid
mkdir -p "$TMP/repo/tests" "$TMP/venv/bin"
cat >"$TMP/repo/tests/test_axes.py" <<'PY'
import pathlib
import sys

mode = sys.argv[1]
if mode == "pass":
    print("covered")
elif mode == "fail":
    raise AssertionError("second changed behavior is broken")
elif mode == "dirty":
    pathlib.Path("review-footprint").write_text("dirty")
elif mode == "network":
    raise OSError("Temporary failure in name resolution")
PY
git -C "$TMP/repo" add tests/test_axes.py
git -C "$TMP/repo" commit -qm base
HEAD_SHA=$(git -C "$TMP/repo" rev-parse HEAD)
ln -s "$(command -v python3)" "$TMP/venv/bin/python"
cat >"$TMP/prescan" <<'EOF'
#!/usr/bin/env bash
jq -cn '{ceiling_posture:"trusted"}'
EOF
chmod +x "$TMP/prescan"

run_plan() {
  local plan=$1
  (cd "$TMP/repo" && GC_CITY_PATH="$ROOT" GC_RIG=vllm GC_PR_TEST_VENV="$TMP/venv" \
    "$GATE" --head "$HEAD_SHA" --base "$HEAD_SHA" --min-ceiling trusted \
      --expect-head-sha "$HEAD_SHA" --prescan "$TMP/prescan" --plan-json "$plan")
}

# Regression fixture: one passing test does not cover a second changed behavior.
# The distinct second-axis check is permitted and exposes its decisive failure.
two_axes=$(jq -cn '{checks:[
  {axis:"streaming-phase-handoff",purpose:"coverage",command:["python","tests/test_axes.py","pass"]},
  {axis:"config-roundtrip",purpose:"coverage",command:["python","tests/test_axes.py","fail"]}
]}')
result=$(run_plan "$two_axes")
jq -e '.schema == "dynamic-verification.v1" and .ran_checks == 2 and
  [.checks[].outcome] == ["pass","fail"] and
  .checks[0].axis == "streaming-phase-handoff" and
  .checks[1].axis == "config-roundtrip"' <<<"$result" >/dev/null \
  || fail "a passing first check prevented independent-axis verification"

# A decisive follow-up is allowed only in the final slot after clean passes.
followup=$(jq -cn '{checks:[
  {axis:"parser",purpose:"coverage",command:["python","tests/test_axes.py","pass"]},
  {axis:"config",purpose:"coverage",command:["python","tests/test_axes.py","pass"]},
  {axis:"parser",purpose:"followup",command:["python","tests/test_axes.py","pass"]}
]}')
result=$(run_plan "$followup")
jq -e '.outcome == "pass" and .ran_checks == 3 and
  .checks[2].purpose == "followup" and
  .budget == {max_checks:3,max_coverage_axes:2,max_followups:1,
    total_timeout_s:600,total_output_cap_bytes:65536,
    elapsed_s:.budget.elapsed_s,output_bytes:.budget.output_bytes}' <<<"$result" >/dev/null \
  || fail "bounded decisive follow-up did not run"
[ "$(jq -r '.checks[0].timeout_s' <<<"$result")" = 200 ] \
  || fail "aggregate time was not divided across checks"

# Bounds and axis semantics are deterministic, not reviewer discretion.
for invalid in \
  '{"checks":[{"axis":"a","purpose":"coverage","command":["python","tests/test_axes.py","pass"]},{"axis":"a","purpose":"coverage","command":["python","tests/test_axes.py","pass"]}]}' \
  '{"checks":[{"axis":"a","purpose":"followup","command":["python","tests/test_axes.py","pass"]},{"axis":"b","purpose":"coverage","command":["python","tests/test_axes.py","pass"]}]}' \
  '{"checks":[{"axis":"a","purpose":"coverage","command":["python","tests/test_axes.py","pass"]},{"axis":"b","purpose":"coverage","command":["python","tests/test_axes.py","pass"]},{"axis":"c","purpose":"coverage","command":["python","tests/test_axes.py","pass"]}]}'
do
  if run_plan "$invalid" >"$TMP/invalid.out" 2>&1; then fail "invalid budget plan was accepted"; fi
  grep -q 'invalid plan' "$TMP/invalid.out" || fail "invalid plan lacked a stable refusal"
done

# Every sub-check retains exact-head, allowlist, network classification, and
# cleanliness enforcement; a dirty check prevents the follow-up.
bad_head=$(cd "$TMP/repo" && GC_CITY_PATH="$ROOT" GC_RIG=vllm GC_PR_TEST_VENV="$TMP/venv" \
  "$GATE" --head "$HEAD_SHA" --base "$HEAD_SHA" --min-ceiling trusted \
    --expect-head-sha deadbeef --prescan "$TMP/prescan" --plan-json \
    '{"checks":[{"axis":"head","purpose":"coverage","command":["python","tests/test_axes.py","pass"]}]}')
jq -e '.checks[0].outcome == "skipped" and (.checks[0].reason_if_skipped | contains("head-moved"))' \
  <<<"$bad_head" >/dev/null || fail "exact-head pinning was weakened"

out_scope=$(run_plan '{"checks":[{"axis":"scope","purpose":"coverage","command":["python","app/test.py"]}]}')
jq -e '.checks[0].outcome == "skipped" and (.checks[0].reason_if_skipped | contains("out-of-scope"))' \
  <<<"$out_scope" >/dev/null || fail "path allowlist was weakened"

network=$(run_plan '{"checks":[{"axis":"egress","purpose":"coverage","command":["python","tests/test_axes.py","network"]}]}')
jq -e '.checks[0].network_hint == true' <<<"$network" >/dev/null \
  || fail "egress failure classification was lost"

dirty=$(run_plan '{"checks":[
  {"axis":"cleanliness","purpose":"coverage","command":["python","tests/test_axes.py","dirty"]},
  {"axis":"cleanliness","purpose":"followup","command":["python","tests/test_axes.py","pass"]}
]}')
jq -e '.ran_checks == 1 and .git_clean_after == false and
  (.reason_if_stopped | contains("worktree-mutation"))' <<<"$dirty" >/dev/null \
  || fail "dirty worktree did not stop the verification plan"

printf 'dynamic verification budget: ok\n'
