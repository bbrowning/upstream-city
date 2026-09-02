#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
EMIT="$ROOT/dev-pack/assets/scripts/emit-local-change.sh"
SLING="$ROOT/dev-pack/assets/scripts/sling-change-lifecycle.sh"
DECIDE="$ROOT/dev-pack/assets/scripts/decide-change-lifecycle.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Formula-level shape: both intent front ends hand off to one N=2 lifecycle, while
# the N=1 variant shares the same final decision contract.
python3 - "$ROOT" <<'PY'
import sys, tomllib
from pathlib import Path
root = Path(sys.argv[1])
q = tomllib.loads((root/'dev-pack/formulas/change-lifecycle.toml').read_text())
s = tomllib.loads((root/'dev-pack/formulas/change-lifecycle-solo.toml').read_text())
assert [x['id'] for x in q['steps']] == ['triage','review-lane-a','review-lane-b','synthesize','settle-gate','close-or-revise']
assert [x['id'] for x in s['steps']] == ['triage','review','close-or-revise']
assert q['steps'][4]['needs'] == ['synthesize','review-lane-a','review-lane-b']
for name in ('feature-dev.toml','hard-bug-finalize.toml'):
    f = tomllib.loads((root/'dev-pack/formulas'/name).read_text())
    assert f['vars']['review_n']['default'] == '2'
    assert f['steps'][-1]['id'] == 'review-handoff'
    assert 'sling-change-lifecycle.sh' in f['steps'][-1]['description']
for name in ('hard-bug-round.toml','hard-bug-round-solo.toml'):
    f = tomllib.loads((root/'dev-pack/formulas'/name).read_text())
    assert f['vars']['review_n']['default'] == '2'
    assert 'review_lane_a_target' in f['steps'][-1]['description']
for name in ('change-lifecycle.toml','change-lifecycle-solo.toml'):
    text = (root/'dev-pack/formulas'/name).read_text()
    assert 'exactly this canonical tuple and no other keys' in text
    assert 'Do not embed the full local-change object there' in text
PY

feature_dry=$(GC_BIN=gc "$ROOT/dev-pack/commands/feature/run.sh" paude-feature \
  --rig paude --offline --review-n 2 \
  --review-lanes pr-reviewer-a-efficient-medium,pr-reviewer-b-efficient-medium --dry-run)
printf '%s' "$feature_dry" | grep -q 'review_lane_a_target=paude/pr-reviewer-a-efficient-medium' \
  || fail 'feature profile A selection was lost'
printf '%s' "$feature_dry" | grep -q 'review_lane_b_target=paude/pr-reviewer-b-efficient-medium' \
  || fail 'feature profile B selection was lost'
bug_dry=$(GC_BIN=gc "$ROOT/dev-pack/commands/bug/run.sh" paude-bug \
  --rig paude --review-n 1 --review-lanes pr-reviewer-a-efficient-medium --dry-run)
printf '%s' "$bug_dry" | grep -q 'review_n=1' || fail 'hard-bug review N selection was lost'
printf '%s' "$bug_dry" | grep -q 'review_lane_a_target=paude/pr-reviewer-a-efficient-medium' \
  || fail 'hard-bug profile selection was lost'

git init -q -b main "$TMP/repo"
git -C "$TMP/repo" config user.name Fixture
git -C "$TMP/repo" config user.email fixture@example.com
printf 'base\n' >"$TMP/repo/change.txt"
git -C "$TMP/repo" add change.txt
git -C "$TMP/repo" commit -qm 'Create lifecycle fixture' -m 'Provide a stable base for immutable artifact lifecycle tests.'
BASE_SHA=$(git -C "$TMP/repo" rev-parse HEAD)
printf '[]\n' >"$TMP/checks.json"

make_artifact() { # intent branch revision previous feedback verdict output
  local intent=$1 branch=$2 revision=$3 previous=$4 feedback=$5 verdict=$6 output=$7
  args=(--repo "$TMP/repo" --rig fixture --workflow fixture --bead "fixture-$intent"
    --intent "$intent" --base "$BASE_SHA" --branch "$branch"
    --verification-file "$TMP/checks.json" --revision "$revision" --output "$output")
  if [ "$revision" -gt 1 ]; then
    args+=(--previous-artifact "$previous" --feedback-bead "$feedback" --verdict "$verdict")
  fi
  "$EMIT" "${args[@]}"
}

git -C "$TMP/repo" switch -qc feature/lifecycle
printf 'feature r1\n' >>"$TMP/repo/change.txt"
git -C "$TMP/repo" commit -qam 'Implement lifecycle feature' -m 'Exercise the initial feature artifact and bounded review handoff.'
make_artifact feature feature/lifecycle 1 '' '' '' "$TMP/feature-r1.json"
FEATURE_ID=$(jq -r .artifact_id "$TMP/feature-r1.json")
FEATURE_HEAD=$(jq -r .head.sha "$TMP/feature-r1.json")

git -C "$TMP/repo" switch -q main
git -C "$TMP/repo" switch -qc bug/lifecycle
printf 'bug r1\n' >>"$TMP/repo/change.txt"
git -C "$TMP/repo" commit -qam 'Fix lifecycle bug' -m 'Exercise hard-bug review settlement against an immutable artifact.'
make_artifact hard_bug bug/lifecycle 1 '' '' '' "$TMP/bug-r1.json"
BUG_ID=$(jq -r .artifact_id "$TMP/bug-r1.json")
BUG_HEAD=$(jq -r .head.sha "$TMP/bug-r1.json")

mkdir -p "$TMP/bin"
printf '%s\n' '{"status":"open","metadata":{}}' >"$TMP/state.json"
: >"$TMP/gc.log"
cat >"$TMP/bin/gc" <<'GC'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${MOCK_GC_LOG:?}"; printf '\n' >>"$MOCK_GC_LOG"
while [ $# -gt 0 ]; do case "$1" in --city|--rig) shift 2 ;; *) break ;; esac; done
case "${1-} ${2-}" in
  "rig list") jq -cn --arg path "${MOCK_REPO:?}" '{rigs:[{name:"fixture",path:$path}]}' ;;
  "bd show") jq -c '[.]' "${MOCK_GC_STATE:?}" ;;
  "bd update")
    shift 3; next="${MOCK_GC_STATE}.next"; cp "$MOCK_GC_STATE" "$next"
    while [ $# -gt 0 ]; do
      case "$1" in
        --set-metadata) pair=$2; key=${pair%%=*}; value=${pair#*=}; jq --arg k "$key" --arg v "$value" '.metadata[$k]=$v' "$next" >"$next.tmp"; mv "$next.tmp" "$next"; shift 2 ;;
        --status) jq --arg v "$2" '.status=$v' "$next" >"$next.tmp"; mv "$next.tmp" "$next"; shift 2 ;;
        *) shift ;;
      esac
    done
    mv "$next" "$MOCK_GC_STATE"; printf '%s\n' 'mock gc update success' ;;
  "bd close") jq '.status="closed"' "$MOCK_GC_STATE" >"$MOCK_GC_STATE.next"; mv "$MOCK_GC_STATE.next" "$MOCK_GC_STATE"; printf '%s\n' 'mock gc close success' ;;
  "mail send") : ;;
  sling*) : ;;
  *) printf 'unexpected gc call: %s\n' "$*" >&2; exit 99 ;;
esac
GC
chmod +x "$TMP/bin/gc"
export GC_BIN="$TMP/bin/gc" GC_CITY_PATH="$ROOT" MOCK_GC_LOG="$TMP/gc.log"
export MOCK_GC_STATE="$TMP/state.json" MOCK_REPO="$TMP/repo"

# Both intent types enter the real N=2 formula with artifact-derived immutable SHAs.
"$SLING" --rig fixture --work-bead fixture-feature --intent feature \
  --artifact "$TMP/feature-r1.json" --n 2 --max-iterations 3 \
  --revision-formula feature-dev --revision-target fixture/feature-dev-frontier-xhigh --base "$BASE_SHA"
grep -q 'change-lifecycle --formula' "$TMP/gc.log" || fail 'feature did not enter N=2 lifecycle'
grep -q "head_ref=$FEATURE_HEAD" "$TMP/gc.log" || fail 'feature lifecycle did not pin exact head SHA'
grep -q 'lane_a_target=fixture/pr-reviewer-a-frontier-high' "$TMP/gc.log" \
  || fail 'feature helper default lost semantic review A'
grep -q 'lane_b_target=fixture/pr-reviewer-b-frontier-high' "$TMP/gc.log" \
  || fail 'feature helper default lost semantic review B'
grep -q 'triage_target=fixture/pr-triage' "$TMP/gc.log" || fail 'feature helper lost fixed triage'
grep -q 'synthesis_target=fixture/pr-review-synthesizer' "$TMP/gc.log" || fail 'feature helper lost fixed synthesis'
! grep -q 'reviewer_target=' "$TMP/gc.log" || fail 'feature helper retained legacy reviewer target'
: >"$TMP/gc.log"
"$SLING" --rig fixture --work-bead fixture-hard_bug --intent hard_bug \
  --artifact "$TMP/bug-r1.json" --n 2 --max-iterations 3 \
  --revision-formula hard-bug-finalize --revision-target fixture/bug-worker-a-frontier-xhigh --base "$BASE_SHA" \
  --implementer-target fixture/bug-worker-a-frontier-xhigh \
  --coordinator-target fixture/bug-coordinator
grep -q "head_ref=$BUG_HEAD" "$TMP/gc.log" || fail 'hard-bug lifecycle did not pin exact head SHA'
grep -q 'lane_a_target=fixture/pr-reviewer-a-frontier-high' "$TMP/gc.log" \
  || fail 'hard-bug helper default lost semantic review A'
grep -q 'lane_b_target=fixture/pr-reviewer-b-frontier-high' "$TMP/gc.log" \
  || fail 'hard-bug helper default lost semantic review B'

# Feature request_changes creates revision 2 with explicit lineage and leaves parent open.
printf '%s\n' '{"schema":"pr-review-quorum.v1","verdict":"request_changes","has_disputed_major":false}' >"$TMP/feature-synth.json"
: >"$TMP/gc.log"
"$DECIDE" --rig fixture --work-bead fixture-feature --intent feature \
  --artifact-id "$FEATURE_ID" --head-sha "$FEATURE_HEAD" --branch feature/lifecycle \
  --revision 1 --max-iterations 3 --synthesis-file "$TMP/feature-synth.json" \
  --feedback-bead synth-feature --revision-formula feature-dev \
  --revision-target fixture/feature-dev-efficient-medium --base "$BASE_SHA" >"$TMP/feature-decision.json"
jq -e '.action == "revision_slung" and .effective_verdict == "request_changes"' "$TMP/feature-decision.json" >/dev/null
grep -q 'revision=2' "$TMP/gc.log" || fail 'feature revision was not incremented'
grep -q "previous_artifact_id=$FEATURE_ID" "$TMP/gc.log" || fail 'feature revision lost lineage'
grep -q 'implementer_target=fixture/feature-dev-efficient-medium' "$TMP/gc.log" \
  || fail 'feature revision lost semantic implementer target'
jq -e '.status == "in_progress"' "$TMP/state.json" >/dev/null || fail 'revision closed parent'

# Exhaustion routes the exact immutable evidence to the rig lead, without a mayor hold.
: >"$TMP/gc.log"
"$DECIDE" --rig fixture --work-bead fixture-feature --intent feature \
  --artifact-id "$FEATURE_ID" --head-sha "$FEATURE_HEAD" --branch feature/lifecycle \
  --revision 3 --max-iterations 3 --synthesis-file "$TMP/feature-synth.json" \
  --feedback-bead synth-feature --synthesis-bead synth-feature \
  --revision-formula feature-dev --revision-target fixture/feature-dev-frontier-xhigh --base "$BASE_SHA" \
  >"$TMP/feature-exhausted.json"
jq -e '.action == "lead_escalated" and .effective_verdict == "request_changes"' "$TMP/feature-exhausted.json" >/dev/null
grep -q 'mail send fixture/lead .*--notify' "$TMP/gc.log" || fail 'exhaustion did not wake fixture lead'
! grep -q 'hold=mayor\|hold=lead' "$TMP/gc.log" || fail 'routine lifecycle exhaustion applied a hold'
jq -e '(.metadata["gc.lead_escalation_json"] | fromjson |
  .artifact_id == $id and .head_sha == $head and .iteration == 3 and .notified)' \
  --arg id "$FEATURE_ID" --arg head "$FEATURE_HEAD" "$TMP/state.json" >/dev/null \
  || fail 'lead escalation evidence was not durable'

# Hard-bug request_changes preserves implementation, coordinator, review targets, and N.
printf '%s\n' '{"schema":"pr-review-quorum.v1","verdict":"request_changes","has_disputed_major":false}' >"$TMP/bug-request.json"
: >"$TMP/gc.log"
"$DECIDE" --rig fixture --work-bead fixture-hard_bug --intent hard_bug \
  --artifact-id "$BUG_ID" --head-sha "$BUG_HEAD" --branch bug/lifecycle \
  --revision 1 --max-iterations 3 --synthesis-file "$TMP/bug-request.json" \
  --feedback-bead synth-bug --revision-formula hard-bug-finalize \
  --revision-target fixture/bug-worker-a-frontier-xhigh --base "$BASE_SHA" \
  --implementer-target fixture/bug-worker-a-frontier-xhigh \
  --coordinator-target fixture/bug-coordinator --review-n 1 \
  --lane-a-target fixture/pr-reviewer-a-efficient-medium \
  --lane-b-target fixture/pr-reviewer-b-efficient-medium >"$TMP/bug-request-decision.json"
for expected in 'fixture/bug-worker-a-frontier-xhigh hard-bug-finalize --formula' \
  'implementer_target=fixture/bug-worker-a-frontier-xhigh' \
  'coordinator_target=fixture/bug-coordinator' 'review_n=1' \
  'review_lane_a_target=fixture/pr-reviewer-a-efficient-medium' \
  'review_lane_b_target=fixture/pr-reviewer-b-efficient-medium' 'revision=2'; do
  grep -q "$expected" "$TMP/gc.log" || fail "hard-bug revision lost $expected"
done
! grep -q 'reviewer_target=' "$TMP/gc.log" || fail 'hard-bug revision retained legacy reviewer target'

# A load-bearing hard-bug disagreement is settled by evidence before approval/closure.
printf '%s\n' '{"schema":"pr-review-quorum.v1","verdict":"request_changes","has_disputed_major":true}' >"$TMP/bug-synth.json"
printf '%s\n' '{"schema":"pr-review-settle.v1","settled_verdict":"approve"}' >"$TMP/bug-settle.json"
: >"$TMP/gc.log"
"$DECIDE" --rig fixture --work-bead fixture-hard_bug --intent hard_bug \
  --artifact-id "$BUG_ID" --head-sha "$BUG_HEAD" --branch bug/lifecycle \
  --revision 1 --max-iterations 3 --synthesis-file "$TMP/bug-synth.json" \
  --settle-file "$TMP/bug-settle.json" --feedback-bead settle-bug >"$TMP/bug-decision.json"
jq -e '.action == "approved" and .effective_verdict == "approve"' "$TMP/bug-decision.json" >/dev/null
jq -e '.status == "closed" and (.metadata["gc.lifecycle_json"] | fromjson | .artifact_id == $id and .head_sha == $head)' \
  --arg id "$BUG_ID" --arg head "$BUG_HEAD" "$TMP/state.json" >/dev/null || fail 'settled approval did not close exact checkpoint'
! grep -q ' sling ' "$TMP/gc.log" || fail 'settled approval launched an unnecessary revision'

printf 'change lifecycle e2e: ok\n'
