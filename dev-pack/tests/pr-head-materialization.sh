#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MATERIALIZE="$ROOT/dev-pack/assets/scripts/materialize-pr-head.sh"
REVIEW="$ROOT/dev-pack/commands/review/run.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_fail() {
    local pattern="$1"; shift
    local out
    if out=$("$@" 2>&1); then fail "command unexpectedly succeeded: $*"; fi
    [[ "$out" == *"$pattern"* ]] || fail "failure did not contain '$pattern': $out"
}

# Build an origin whose PR object is absent from the consumer clone until the
# materialization fetch publishes it into the shared object store.
git init -q --bare "$TMP/origin.git"
git init -q "$TMP/source"
git -C "$TMP/source" config user.name test
git -C "$TMP/source" config user.email test@example.com
printf 'base\n' > "$TMP/source/value.txt"
git -C "$TMP/source" add value.txt
git -C "$TMP/source" commit -qm base
BASE_SHA=$(git -C "$TMP/source" rev-parse HEAD)
git -C "$TMP/source" branch -M main
git -C "$TMP/source" remote add origin "$TMP/origin.git"
git -C "$TMP/source" push -q origin main
printf 'pr\n' >> "$TMP/source/value.txt"
git -C "$TMP/source" commit -qam pr
PR_SHA=$(git -C "$TMP/source" rev-parse HEAD)
git -C "$TMP/source" push -q origin "HEAD:refs/pull/42/head"
git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q --no-local "$TMP/origin.git" "$TMP/repo"

cat > "$TMP/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  'api repos/{owner}/{repo}/pulls/42'|'api repos/{owner}/{repo}/pulls/99')
    jq -cn --arg sha "${GH_TEST_SHA:?}" '{head:{sha:$sha},author_association:"MEMBER",user:{login:"tester"}}' ;;
  'pr view') printf '%s\n' '{"files":[{"path":"value.txt"}]}' ;;
  *) exit 1 ;;
esac
GH
chmod +x "$TMP/gh"
export PATH="$TMP:$PATH" GH_TEST_SHA="$PR_SHA"

[ ! -e "$TMP/repo/.git/objects/${PR_SHA:0:2}/${PR_SHA:2}" ] \
    || fail 'PR object unexpectedly existed before materialization'
OUT=$("$MATERIALIZE" --repo "$TMP/repo" --pr 42)
[ "$OUT" = "$PR_SHA" ] || fail "wrong materialized SHA: $OUT"
[ "$(git -C "$TMP/repo" rev-parse "refs/gc/pr-heads/42/$PR_SHA")" = "$PR_SHA" ] \
    || fail 'immutable ready ref was not published'
git -C "$TMP/repo" cat-file -e "$PR_SHA^{commit}" || fail 'PR commit is missing after publish'
[ -z "$(git -C "$TMP/repo" for-each-ref refs/gc/pr-head-staging/)" ] \
    || fail 'staging ref leaked after publish'

# A moved advertised head must not publish under the old/new identity, and a
# missing pull ref is explicitly reported as infrastructure rather than evidence.
export GH_TEST_SHA="$BASE_SHA"
expect_fail 'pr-head-drift' "$MATERIALIZE" --repo "$TMP/repo" --pr 42
! git -C "$TMP/repo" show-ref --verify --quiet "refs/gc/pr-heads/42/$BASE_SHA" \
    || fail 'drifted head was published'
expect_fail 'pr-head-fetch-failed' "$MATERIALIZE" --repo "$TMP/repo" --pr 99

# Pre-scan consumes the pinned local commit, still reads PR metadata, and treats
# disappearance of the assigned object as transient infrastructure failure.
export GH_TEST_SHA="$PR_SHA" GC_RIG=vllm
(cd "$TMP/repo" && "$ROOT/dev-pack/assets/scripts/pr-prescan.sh" 42 origin/main "$PR_SHA") \
    | jq -e --arg sha "$PR_SHA" '.source == "gh-pr" and .head_ref == "42" and .facts.changed_files == ["value.txt"]' >/dev/null \
    || fail 'pre-scan did not use the materialized immutable head'
MISSING=$(printf 'f%.0s' $(seq 1 40))
export GH_TEST_SHA="$MISSING"
expect_fail 'materialized PR head' bash -c \
    'cd "$1" && "$2" 42 origin/main "$3"' _ "$TMP/repo" "$ROOT/dev-pack/assets/scripts/pr-prescan.sh" "$MISSING"

# The launcher completes materialization before sling and carries both identities:
# PR number for metadata/output, immutable SHA for all local review operations.
cat > "$TMP/gc" <<'GC'
#!/usr/bin/env bash
args=" $* "
if [[ "$args" == *" rig list --json "* ]]; then
  jq -cn --arg path "${GC_TEST_REPO:?}" '{rigs:[{name:"vllm",path:$path}]}'
elif [[ "$args" == *" agent list "* ]]; then
  printf '%s\n' vllm/pr-review-synthesizer vllm/pr-triage \
    vllm/pr-reviewer-a-frontier-xhigh vllm/pr-reviewer-b-frontier-xhigh vllm/pr-arbiter
elif [[ "$args" == *" bd list "* ]]; then
  printf '%s\n' '[]'
elif [[ "$args" == *" bd create "* ]]; then
  printf '%s\n' 'vllm-human-42'
elif [[ "$args" == *" sling "* ]]; then
  printf '%s\n' "$*" > "${GC_TEST_LOG:?}"
  printf '%s\n' '{"id":"vllm-workflow"}'
else
  printf 'unexpected gc call: %s\n' "$*" >&2
  exit 99
fi
GC
chmod +x "$TMP/gc"
export GH_TEST_SHA="$PR_SHA" GC_TEST_REPO="$TMP/repo" GC_TEST_LOG="$TMP/sling.log"
GC_BIN="$TMP/gc" GC_CITY_PATH="$ROOT" "$REVIEW" 42 --rig vllm >/dev/null
grep -Fq -- "--var expected_head_sha=$PR_SHA" "$GC_TEST_LOG" \
    || fail 'launcher did not pass the pinned head SHA'
grep -Fq -- '--var head_ref=42' "$GC_TEST_LOG" \
    || fail 'launcher did not preserve the PR identity'
grep -Fq -- '--var human_source_bead=vllm-human-42' "$GC_TEST_LOG" \
    || fail 'launcher did not link the canonical human-facing source bead'

printf '%s\n' 'ok: atomic PR-head materialization before review dispatch'
