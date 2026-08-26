#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
EMIT_CHANGE="$ROOT/dev-pack/assets/scripts/emit-local-change.sh"
EMIT_VERDICT="$ROOT/dev-pack/assets/scripts/emit-verdict.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

git init -q -b main "$TMP/repo"
git -C "$TMP/repo" config user.name Test
git -C "$TMP/repo" config user.email test@example.invalid
printf 'base\n' >"$TMP/repo/file.txt"
git -C "$TMP/repo" add file.txt
git -C "$TMP/repo" commit -qm base
git -C "$TMP/repo" switch -qc feature/provenance
printf 'change\n' >>"$TMP/repo/file.txt"
git -C "$TMP/repo" commit -qam change
printf '[]\n' >"$TMP/checks.json"
"$EMIT_CHANGE" --repo "$TMP/repo" --rig fixture --workflow feature-dev --bead fixture-impl \
  --intent feature --base main --branch feature/provenance --verification-file "$TMP/checks.json" \
  --revision 1 --output "$TMP/artifact.json"

REF="$TMP/artifact.json"
ID=$(jq -r .artifact_id "$REF")
REPO_ID=$(jq -r .repository.id "$REF")
BRANCH=$(jq -r .head.branch "$REF")
REVISION=$(jq -r .revision.number "$REF")
BASE=$(jq -r .base.sha "$REF")
HEAD=$(jq -r .head.sha "$REF")
EXPECTED=$(jq -cn --arg ref "$REF" --arg id "$ID" --arg repo "$REPO_ID" --arg branch "$BRANCH" \
  --argjson revision "$REVISION" --arg base "$BASE" --arg head "$HEAD" \
  '{artifact_ref:$ref,artifact_id:$id,repository_id:$repo,branch:$branch,revision:$revision,base_sha:$base,head_sha:$head}')

mkdir -p "$TMP/bin"
cat >"$TMP/bin/gc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_GC_LOG"
EOF
chmod +x "$TMP/bin/gc"

emit() {
  local bead=$1 verdict=$2
  MOCK_GC_LOG="$TMP/gc.log" GC_BIN="$TMP/bin/gc" GC_RIG=fixture GC_PR_NOTIFY_TO='' \
    "$EMIT_VERDICT" --bead "$bead" --verdict-file "$verdict" --outcome pass --repo "$TMP/repo" \
      --implementation-artifact-ref "$REF" --implementation-artifact-id "$ID" \
      --implementation-repository-id "$REPO_ID" --implementation-branch "$BRANCH" \
      --implementation-revision "$REVISION" --implementation-base-sha "$BASE" \
      --implementation-head-sha "$HEAD"
}

jq -cn --argjson provenance "$EXPECTED" \
  '{verdict:"approve",findings_count:0,implementation_provenance:$provenance}' >"$TMP/good.json"
: >"$TMP/gc.log"
emit fixture-good "$TMP/good.json"
grep -q 'gc.outcome=pass' "$TMP/gc.log" || fail "matching provenance did not pass"
grep -q 'bd close fixture-good' "$TMP/gc.log" || fail "matching provenance did not close"

for field in artifact_ref artifact_id repository_id branch revision base_sha head_sha; do
  jq --arg field "$field" '.implementation_provenance[$field] =
      (if $field == "revision" then 99
       elif $field == "artifact_id" then (.implementation_provenance[$field][0:12])
       else "mismatch" end)' "$TMP/good.json" >"$TMP/bad-$field.json"
  : >"$TMP/gc.log"
  if emit "fixture-bad-$field" "$TMP/bad-$field.json" >"$TMP/bad-$field.out" 2>&1; then
    fail "$field mismatch passed"
  fi
  grep -q 'gc.outcome=fail' "$TMP/gc.log" || fail "$field mismatch did not mark retryable failure"
  grep -q "bd close fixture-bad-$field --reason retry:" "$TMP/gc.log" \
    || fail "$field mismatch did not close the failed attempt for retry"
  ! grep -q 'gc.output_json=' "$TMP/gc.log" || fail "$field mismatch persisted a passing verdict"

  jq --arg field "$field" 'del(.implementation_provenance[$field])' \
    "$TMP/good.json" >"$TMP/missing-$field.json"
  : >"$TMP/gc.log"
  if emit "fixture-missing-$field" "$TMP/missing-$field.json" >/dev/null 2>&1; then
    fail "missing $field passed"
  fi
done

# Fresh resolution remains the final defense even when the emitted object is exact.
git -C "$TMP/repo" switch -q main
git -C "$TMP/repo" branch -f "$BRANCH" "$BASE"
: >"$TMP/gc.log"
if emit fixture-stale "$TMP/good.json" >"$TMP/stale.out" 2>&1; then
  fail "stale branch passed fresh provenance resolution"
fi
grep -q 'fresh artifact resolution failed' "$TMP/stale.out" || fail "fresh resolution failure was unclear"
grep -q 'gc.outcome=fail' "$TMP/gc.log" || fail "fresh resolution failure did not enter retry path"

printf 'review implementation provenance: ok\n'
