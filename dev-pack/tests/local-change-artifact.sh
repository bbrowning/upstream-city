#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
EMIT="$ROOT/dev-pack/assets/scripts/emit-local-change.sh"
RESOLVE="$ROOT/dev-pack/assets/scripts/resolve-local-change.sh"
REVIEW="$ROOT/dev-pack/commands/review/run.sh"
FEATURE="$ROOT/dev-pack/commands/feature/run.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

git init -q -b main "$TMP/repo"
git -C "$TMP/repo" config user.name Test
git -C "$TMP/repo" config user.email test@example.invalid
printf 'base\n' > "$TMP/repo/change.txt"
git -C "$TMP/repo" add change.txt
git -C "$TMP/repo" commit -qm base
git -C "$TMP/repo" switch -qc feature/local-change
printf 'feature\n' >> "$TMP/repo/change.txt"
git -C "$TMP/repo" add change.txt
git -C "$TMP/repo" commit -qm feature -m 'Add the fixture change so artifact provenance can be exercised.'
HEAD_SHA=$(git -C "$TMP/repo" rev-parse HEAD)
BASE_SHA=$(git -C "$TMP/repo" rev-parse main)
printf '[{"command":"test -s change.txt","result":"pass"}]\n' > "$TMP/checks.json"

"$EMIT" --repo "$TMP/repo" --rig paude --workflow feature-dev --bead fixture-1 \
  --intent feature --base main --branch feature/local-change \
  --verification-file "$TMP/checks.json" --revision 1 \
  --base-fetch-status fetched --base-remote-url https://example.invalid/repo.git \
  --base-fetched-ref refs/remotes/origin/main --output "$TMP/artifact.json"
jq -e --arg head "$HEAD_SHA" --arg base "$BASE_SHA" '
  .schema == "local-change.v1" and .producer.intent_kind == "feature" and
  .base.sha == $base and .head.sha == $head and .revision.number == 1 and
  (.artifact_id | test("^[0-9a-f]{64}$")) and .changed_paths == ["change.txt"] and
  .verification[0].result == "pass" and
  .provenance.base_resolution == {fetch_status:"fetched",remote_url:"https://example.invalid/repo.git",fetched_ref:"refs/remotes/origin/main",freshness:"verified"}' \
  "$TMP/artifact.json" >/dev/null || fail "artifact schema/provenance"

# Feature launch controls revision lineage and whether the selected base may be
# refreshed; the formula receives every value instead of hard-coding revision 1.
feature_dry=$(GC_BIN=gc "$FEATURE" fixture-1 --rig paude --dry-run)
printf '%s' "$feature_dry" | grep -q -- '--var revision=1' || fail "feature default revision missing"
printf '%s' "$feature_dry" | grep -q -- '--var fetch_base=true' || fail "feature default fetch policy missing"
feature_r2=$(GC_BIN=gc "$FEATURE" fixture-1 --rig paude --base main --offline --revision 2 \
  --previous-artifact artifact-r1 --feedback-bead review-r1 --verdict request_changes --dry-run)
for expected in 'base=main' 'fetch_base=false' 'revision=2' 'previous_artifact_id=artifact-r1' \
  'feedback_bead=review-r1' 'producing_verdict=request_changes'; do
  printf '%s' "$feature_r2" | grep -q -- "--var $expected" || fail "feature revision launch lost $expected"
done

git -C "$TMP/repo" switch -q main
git -C "$TMP/repo" worktree add -q --detach "$TMP/reviewer" main
"$RESOLVE" --repo "$TMP/reviewer" --rig paude --artifact "$TMP/artifact.json" >/dev/null \
  || fail "linked-worktree artifact resolution"

# A bead carrying a wrapper output resolves to the same canonical object.
mkdir -p "$TMP/bin"
cp "$ROOT/city.toml" "$TMP/city.toml"
cat > "$TMP/bin/gc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
while [ $# -gt 0 ]; do
  case "$1" in --city|--rig) shift 2 ;; *) break ;; esac
done
case "${1:-} ${2:-}" in
  "rig list") jq -cn --arg path "$MOCK_REPO" '{rigs:[{name:"paude",path:$path}]}' ;;
  "agent list") printf '%s\n' paude/pr-reviewer-a-frontier-xhigh paude/pr-reviewer-b-frontier-xhigh paude/pr-review-synthesizer ;;
  "bd show")
    if [ "${3:-}" = fixture-1 ]; then
      jq -cn --rawfile artifact "$MOCK_ARTIFACT" '
        ($artifact|fromjson) as $a |
        [{metadata:{"gc.lifecycle_json":({schema:"work-lifecycle.v1",intent_kind:$a.producer.intent_kind,
          checkpoint:"implementation",disposition:"awaiting_review",iteration:$a.revision.number,
          artifact_id:$a.artifact_id,head_sha:$a.head.sha,branch:$a.head.branch}|tojson)}}]'
    else
      jq -cn --rawfile artifact "$MOCK_ARTIFACT" '[{metadata:{"gc.output_json":({local_change:($artifact|fromjson)}|tojson)}}]'
    fi ;;
  *)
    if printf '%s\n' "${args[@]}" | grep -qx sling; then printf '%s\n' "${args[@]}"; else exit 2; fi ;;
esac
EOF
chmod +x "$TMP/bin/gc"
MOCK_REPO="$TMP/reviewer" MOCK_ARTIFACT="$TMP/artifact.json" GC_BIN="$TMP/bin/gc" GC_CITY_PATH="$TMP" \
  "$RESOLVE" --repo "$TMP/reviewer" --rig paude --artifact fixture-impl >/dev/null \
  || fail "artifact bead resolution"

# The real command routes both solo and bounded N=2 quorum from immutable SHAs.
for n in 1 2; do
  out=$(MOCK_REPO="$TMP/reviewer" MOCK_ARTIFACT="$TMP/artifact.json" GC_BIN="$TMP/bin/gc" GC_CITY_PATH="$TMP" \
    "$REVIEW" --artifact "$TMP/artifact.json" --rig paude --n "$n" --dry-run)
  printf '%s' "$out" | grep -q -- "--var head_ref=$HEAD_SHA" || fail "N=$n did not route immutable head"
  printf '%s' "$out" | grep -q -- "--var base_ref=$BASE_SHA" || fail "N=$n did not route immutable base"
  printf '%s' "$out" | grep -q -- '--var implementation_artifact_id=' || fail "N=$n lost provenance"
done

out=$(MOCK_REPO="$TMP/reviewer" MOCK_ARTIFACT="$TMP/artifact.json" GC_BIN="$TMP/bin/gc" GC_CITY_PATH="$TMP" \
  "$REVIEW" feature/local-change --rig paude --base main --n 1 --dry-run)
printf '%s' "$out" | grep -q -- "--var head_ref=$HEAD_SHA" || fail "explicit local branch did not resolve to immutable head"
printf '%s' "$out" | grep -q -- '--var implementation_artifact_id=explicit-local-ref' || fail "explicit local branch lost provenance"

# Review-driven revisions carry an explicit predecessor and producing verdict.
PREVIOUS_ID=$(jq -r '.artifact_id' "$TMP/artifact.json")
git -C "$TMP/repo" switch -q feature/local-change
printf 'revision two\n' >> "$TMP/repo/change.txt"
git -C "$TMP/repo" add change.txt
git -C "$TMP/repo" commit -qm 'Revise after review' -m 'Record a second artifact revision in response to review feedback.'
"$EMIT" --repo "$TMP/repo" --rig paude --workflow feature-dev --bead fixture-1 \
  --intent feature --base main --branch feature/local-change \
  --verification-file "$TMP/checks.json" --revision 2 --previous-artifact "$PREVIOUS_ID" \
  --feedback-bead fixture-review --verdict request_changes --base-fetch-status offline \
  --output "$TMP/artifact-r2.json"
jq -e --arg previous "$PREVIOUS_ID" '
  .revision.number == 2 and .revision.lineage.previous_artifact_id == $previous and
  .revision.lineage.producing_feedback == {bead:"fixture-review",verdict:"request_changes"} and
  .provenance.base_resolution == {fetch_status:"offline",remote_url:null,fetched_ref:null,freshness:"unverified"}' \
  "$TMP/artifact-r2.json" >/dev/null || fail "revision lineage"
"$RESOLVE" --repo "$TMP/reviewer" --rig paude --artifact "$TMP/artifact-r2.json" >/dev/null \
  || fail "revision 2 resolution"
git -C "$TMP/repo" switch -q main

# Branch movement makes the immutable handoff stale and must fail clearly.
git -C "$TMP/repo" branch -f feature/local-change "$BASE_SHA"
if "$RESOLVE" --repo "$TMP/reviewer" --rig paude --artifact "$TMP/artifact.json" >"$TMP/stale.out" 2>&1; then
  fail "stale branch was accepted"
fi
grep -q 'stale artifact' "$TMP/stale.out" || fail "stale branch failure was unclear"

# A separate clone/worktree identity is cross-repository even with the same commits.
git clone -q "$TMP/repo" "$TMP/other"
if "$RESOLVE" --repo "$TMP/other" --rig paude --artifact "$TMP/artifact.json" >"$TMP/cross.out" 2>&1; then
  fail "cross-repository artifact was accepted"
fi
grep -q 'repository mismatch' "$TMP/cross.out" || fail "cross-repository failure was unclear"

printf 'local-change artifact E2E: ok\n'
