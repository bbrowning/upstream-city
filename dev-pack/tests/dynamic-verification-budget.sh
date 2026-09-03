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
mkdir -p "$TMP/repo/tests" "$TMP/repo/internal/filter" "$TMP/venv/bin" "$TMP/bin"
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
cat >"$TMP/repo/internal/filter/filter_test.go" <<'GO'
package filter

// The mock prepared Go runtime below verifies this package-scoped argv without
// requiring a host Go installation.
GO
git -C "$TMP/repo" add tests/test_axes.py
git -C "$TMP/repo" add internal/filter/filter_test.go
git -C "$TMP/repo" commit -qm base
HEAD_SHA=$(git -C "$TMP/repo" rev-parse HEAD)
ln -s "$(command -v python3)" "$TMP/venv/bin/python"
cat >"$TMP/bin/go" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1-}" in
  version) printf 'go version go1.23.12 linux/amd64\n' ;;
  test)
    shift
    [ "$*" = "./internal/filter -count=1" ] || exit 2
    printf 'ok example.invalid/internal/filter\n'
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/go"
cat >"$TMP/prepare-go" <<'EOF'
#!/usr/bin/env bash
jq -cn --arg executable "$MOCK_GO" \
  '{schema:"prepared-runtime.v1",runtime:"go",executable:$executable}'
EOF
chmod +x "$TMP/prepare-go"
export MOCK_GO="$TMP/bin/go"
cat >"$TMP/prescan" <<'EOF'
#!/usr/bin/env bash
jq -cn '{ceiling_posture:"trusted"}'
EOF
chmod +x "$TMP/prescan"

run_plan() {
  local plan=$1
  local prefix=${2:-tests/}
  (cd "$TMP/repo" && GC_CITY_PATH="$ROOT" GC_RIG=vllm GC_PR_TEST_VENV="$TMP/venv" \
    GC_PREPARE_TEST_ENV="$TMP/prepare-go" \
    "$GATE" --head "$HEAD_SHA" --base "$HEAD_SHA" --min-ceiling trusted \
      --expect-head-sha "$HEAD_SHA" --allow-path-prefix "$prefix" \
      --prescan "$TMP/prescan" --plan-json "$plan")
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

# A typed Go runtime uses a Go health check and substitutes only the prepared
# executable into a narrowly scoped `go test` argv.
go_plan=$(jq -cn '{checks:[
  {axis:"filter-package",purpose:"coverage",command:["go","test","./internal/filter","-count=1"]}
]}')
result=$(run_plan "$go_plan" internal/filter)
jq -e --arg executable "$TMP/bin/go" '.outcome == "pass" and .ran_checks == 1 and
  .checks[0].runtime_type == "go" and .checks[0].env_source == "prepare-hook" and
  .checks[0].env_used == $executable and .checks[0].command == "go test ./internal/filter -count=1"' \
  <<<"$result" >/dev/null || fail "typed prepared Go runtime did not execute"

# Existing project hooks that print only an executable path remain compatible;
# their runtime type is inferred from the already-admitted command family.
cat >"$TMP/prepare-go-legacy" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$MOCK_GO"
EOF
chmod +x "$TMP/prepare-go-legacy"
legacy_go=$(cd "$TMP/repo" && GC_CITY_PATH="$ROOT" GC_RIG=vllm \
  GC_PREPARE_TEST_ENV="$TMP/prepare-go-legacy" \
  "$GATE" --head "$HEAD_SHA" --base "$HEAD_SHA" --min-ceiling trusted \
    --expect-head-sha "$HEAD_SHA" --allow-path-prefix internal/filter \
    --prescan "$TMP/prescan" --plan-json "$go_plan")
jq -e '.outcome == "pass" and .checks[0].runtime_type == "go"' <<<"$legacy_go" >/dev/null \
  || fail "legacy prepared executable output stopped working for Go"

# Go admission remains fail-closed: no arbitrary subcommands/flags, broad package
# wildcard, absolute/import-path targets, or package paths outside the approved scope.
for command in \
  '["go","env"]' \
  '["go","test","./internal/filter","-exec=/tmp/runner"]' \
  '["go","test","./..."]' \
  '["go","test","example.invalid/internal/filter"]'
do
  rejected=$(run_plan "$(jq -cn --argjson command "$command" \
    '{checks:[{axis:"go-grammar",purpose:"coverage",command:$command}]}')" internal/filter)
  jq -e '.checks[0].outcome == "skipped" and .checks[0].ran == false' \
    <<<"$rejected" >/dev/null || fail "unsafe Go command was accepted: $command"
done
go_out_scope=$(run_plan "$go_plan" internal/other)
jq -e '.checks[0].outcome == "skipped" and
  (.checks[0].reason_if_skipped | contains("out-of-scope"))' <<<"$go_out_scope" >/dev/null \
  || fail "Go package scope was weakened"

# A typed runtime must match the admitted command family. A valid executable of
# the wrong type is not probed with the other language's health-check arguments.
cat >"$TMP/prepare-wrong-type" <<'EOF'
#!/usr/bin/env bash
jq -cn --arg executable "$MOCK_GO" \
  '{schema:"prepared-runtime.v1",runtime:"python",executable:$executable}'
EOF
chmod +x "$TMP/prepare-wrong-type"
wrong_type=$(cd "$TMP/repo" && GC_CITY_PATH="$ROOT" GC_RIG=vllm \
  GC_PREPARE_TEST_ENV="$TMP/prepare-wrong-type" \
  "$GATE" --head "$HEAD_SHA" --base "$HEAD_SHA" --min-ceiling trusted \
    --expect-head-sha "$HEAD_SHA" --allow-path-prefix internal/filter \
    --prescan "$TMP/prescan" --plan-json "$go_plan")
jq -e '.checks[0].outcome == "could_not_verify" and
  .checks[0].runtime_type == "go" and .checks[0].ran == false' <<<"$wrong_type" >/dev/null \
  || fail "mismatched typed runtime was accepted"

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
