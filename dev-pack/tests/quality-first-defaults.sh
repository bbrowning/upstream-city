#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FEATURE="$ROOT/dev-pack/commands/feature/run.sh"
BUG="$ROOT/dev-pack/commands/bug/run.sh"
REVIEW="$ROOT/dev-pack/commands/review/run.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() { local text=$1 pattern=$2 message=$3; printf '%s' "$text" | grep -q -- "$pattern" || fail "$message"; }

feature_quality=$(GC_BIN=gc "$FEATURE" paude-feature-1 --rig paude --dry-run)
for expected in 'preset=quality' 'review_n=2' 'local_only=true' 'completion=approved' \
  'feature-dev --formula' 'review_n=2' 'max_review_iterations=3'; do
  expect "$feature_quality" "$expected" "feature quality default lost $expected"
done
feature_fast=$(GC_BIN=gc "$FEATURE" paude-feature-1 --rig paude --fast --dry-run)
expect "$feature_fast" 'preset=fast' 'feature fast preset not exposed'
expect "$feature_fast" 'review_n=1' 'feature fast preset did not opt down to N=1'

bug_quality=$(GC_BIN=gc "$BUG" paude-bug-1 --rig paude --dry-run)
for expected in 'preset=quality' 'diagnosis_n=2' 'loop=true' 'review_n=2' \
  'hard-bug-round --formula' 'max_rounds=3' 'max_review_iterations=3' \
  'local_only=true' 'completion=approved'; do
  expect "$bug_quality" "$expected" "bug quality default lost $expected"
done
bug_fast=$(GC_BIN=gc "$BUG" paude-bug-1 --rig paude --fast --dry-run)
expect "$bug_fast" 'preset=fast' 'bug fast preset not exposed'
expect "$bug_fast" 'hard-bug-round-solo --formula' 'bug fast preset did not select solo formula'
expect "$bug_fast" 'loop=true' 'bug fast preset silently became report-only'
expect "$bug_fast" 'review_n=1' 'bug fast preset did not opt implementation review down to N=1'
expect "$bug_fast" 'completion=approved' 'bug fast preset lost approved completion semantics'
bug_report=$(GC_BIN=gc "$BUG" paude-bug-1 --rig paude --report-only --dry-run)
expect "$bug_report" 'preset=report_only' 'bug report-only preset not explicit'
expect "$bug_report" 'diagnosis_n=2' 'bug report-only lost quality diagnosis fan-out'
expect "$bug_report" 'loop=false' 'bug report-only unexpectedly enabled implementation'
expect "$bug_report" 'completion=report_only' 'bug report-only advertises implementation approval'

cat >"$TMP/gc" <<GC
#!/usr/bin/env bash
args=" \$* "
if [[ "\$args" == *" rig list --json "* ]]; then
  jq -cn --arg path "$ROOT" '{rigs:[{name:"paude",path:\$path}]}'
elif [[ "\$args" == *" agent list "* ]]; then
  printf '%s\n' paude/pr-review-synthesizer paude/pr-reviewer-a-frontier-xhigh paude/pr-reviewer-b-frontier-xhigh
else
  printf 'unexpected gc call: %s\n' "\$*" >&2; exit 99
fi
GC
chmod +x "$TMP/gc"
review_quality=$(GC_BIN="$TMP/gc" GC_CITY_PATH="$ROOT" "$REVIEW" 123 --rig paude --dry-run)
for expected in 'preset=quality' 'n=2' 'pr-review-quorum --formula' \
  'lane_a_target=paude/pr-reviewer-a-frontier-xhigh' \
  'lane_b_target=paude/pr-reviewer-b-frontier-xhigh' 'settle=true' 'enable_settle=true' 'completion=human_checkpoint'; do
  expect "$review_quality" "$expected" "review quality default lost $expected"
done
review_fast=$(GC_BIN="$TMP/gc" GC_CITY_PATH="$ROOT" "$REVIEW" 123 --rig paude --solo --dry-run)
expect "$review_fast" 'preset=fast' 'review fast/solo preset not exposed'
expect "$review_fast" 'pr-review --formula' 'review fast/solo did not select N=1 formula'
expect "$review_fast" 'settle=false' 'review N=1 unexpectedly enabled settlement'
review_report=$(GC_BIN="$TMP/gc" GC_CITY_PATH="$ROOT" "$REVIEW" 123 --rig paude --report-only --dry-run)
expect "$review_report" 'settle=false' 'review report-only opt-out did not disable settlement'

lead="$ROOT/agents/lead/prompt.template.md"
for request in 'Implement this feature' 'Fix this bug' 'Review PR N'; do
  grep -q "$request" "$lead" || fail "lead prompt missing plain-language request: $request"
done
grep -q 'must not be implemented ad hoc in the rig root' "$lead" || fail 'lead can bypass the lifecycle'
grep -q 'never pushes, publishes, opens, or merges a PR' "$lead" || fail 'lead prompt lost local-only checkpoint'

printf 'quality-first defaults: ok\n'
