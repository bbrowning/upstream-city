#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
VALIDATE="$ROOT/dev-pack/assets/scripts/validate-commit-series.py"
EMIT="$ROOT/dev-pack/assets/scripts/emit-local-change.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

new_repo() {
  local repo=$1
  git init -q -b main "$repo"
  git -C "$repo" config user.name Test
  git -C "$repo" config user.email test@example.invalid
  printf 'base\n' >"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm base
  git -C "$repo" switch -qc feature/messages
}

commit_with_file() {
  local repo=$1 message=$2 content=$3
  printf '%s\n' "$content" >>"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qF "$message"
}

new_repo "$TMP/good"
printf 'Add observable behavior\n\nExplain what changes and why the workflow needs it.\n' >"$TMP/good-message"
commit_with_file "$TMP/good" "$TMP/good-message" good
"$VALIDATE" --repo "$TMP/good" --base main --head HEAD --output "$TMP/good.json"
jq -e '.valid and .commits[0].body != "" and .commits[0].message_sha256 != ""' \
  "$TMP/good.json" >/dev/null || fail "valid message evidence"

assert_rule() {
  local name=$1 message=$2 rule=$3
  local repo="$TMP/$name"
  new_repo "$repo"
  printf '%s' "$message" >"$TMP/$name-message"
  commit_with_file "$repo" "$TMP/$name-message" "$name"
  if "$VALIDATE" --repo "$repo" --base main --head HEAD --output "$TMP/$name.json" \
      >"$TMP/$name.out" 2>&1; then
    fail "$name escaped commit-message validation"
  fi
  jq -e --arg rule "$rule" '.violations[] | select(.rule == $rule and (.sha | length == 40))' \
    "$TMP/$name.json" >/dev/null || fail "$name did not report SHA and rule $rule"
}

assert_rule subject-only 'Add subject only
' empty-body
assert_rule no-separation 'Add a subject
Body starts without the required blank separator.
' missing-subject-body-separation
assert_rule fragmented 'Add coherent behavior

Explain the behavior and

why the workflow requires it.
' malformed-fragmented-paragraph-wrapping

long_subject=$(printf 'A%.0s' {1..73})
assert_rule long-subject "$long_subject

Explain what changes and why it is needed.
" subject-over-72-characters

# Repository-local AGENTS.md can tighten the default line budget.
new_repo "$TMP/local-policy"
git -C "$TMP/local-policy" switch -q main
printf '%s\n' 'Write commit messages with a concise what/why body below the subject, wrapping all lines at 50 characters.' \
  >"$TMP/local-policy/AGENTS.md"
git -C "$TMP/local-policy" add AGENTS.md
git -C "$TMP/local-policy" commit -qm 'Add repository policy'
git -C "$TMP/local-policy" branch -D feature/messages >/dev/null
git -C "$TMP/local-policy" switch -qc feature/messages
printf 'Add policy coverage\n\nThis body line is deliberately longer than fifty characters for policy discovery.\n' \
  >"$TMP/local-policy-message"
commit_with_file "$TMP/local-policy" "$TMP/local-policy-message" policy
if "$VALIDATE" --repo "$TMP/local-policy" --base main --head HEAD --output "$TMP/policy.json" >/dev/null 2>&1; then
  fail "repository-local 50-character policy was ignored"
fi
jq -e '.policy.body_max == 50 and (.policy.sources | index("AGENTS.md"))' "$TMP/policy.json" >/dev/null \
  || fail "repository-local policy evidence"

# The artifact boundary invokes the same validator and preserves its audit evidence.
printf '[]\n' >"$TMP/checks.json"
"$EMIT" --repo "$TMP/good" --rig fixture --workflow feature-dev --bead fixture-1 \
  --intent feature --base main --branch feature/messages --verification-file "$TMP/checks.json" \
  --revision 1 --output "$TMP/artifact.json"
jq -e '.commit_message_quality.schema == "commit-series-quality.v1" and
  .commit_message_quality.valid and .commits[0].body != "" and .commits[0].message_sha256 != ""' \
  "$TMP/artifact.json" >/dev/null || fail "artifact omitted commit-message audit evidence"

new_repo "$TMP/bad-artifact"
printf 'bad\n' >>"$TMP/bad-artifact/file.txt"
git -C "$TMP/bad-artifact" commit -qam 'Subject only'
if "$EMIT" --repo "$TMP/bad-artifact" --rig fixture --workflow feature-dev --bead fixture-bad \
    --intent feature --base main --branch feature/messages --verification-file "$TMP/checks.json" \
    --revision 1 --output "$TMP/bad-artifact.json" >"$TMP/bad-artifact.out" 2>&1; then
  fail "artifact emission accepted a subject-only commit"
fi
grep -q 'commit message quality gate failed' "$TMP/bad-artifact.out" \
  || fail "artifact quality failure was unclear"

printf 'commit series quality: ok\n'
