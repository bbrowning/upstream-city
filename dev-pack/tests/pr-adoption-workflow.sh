#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PREPARE="$ROOT/dev-pack/assets/scripts/prepare-pr-adoption.sh"
EMIT="$ROOT/dev-pack/assets/scripts/emit-local-change.sh"
DECIDE="$ROOT/dev-pack/assets/scripts/decide-change-lifecycle.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

git init -q --bare "$TMP/origin.git"
git init -q -b main "$TMP/seed"
git -C "$TMP/seed" config user.name Maintainer
git -C "$TMP/seed" config user.email maintainer@example.com
printf 'base\n' > "$TMP/seed/file"
git -C "$TMP/seed" add file
git -C "$TMP/seed" commit -qm 'Create fixture base' -m 'Provide the initial branch point for adoption tests.'
OLD_BASE=$(git -C "$TMP/seed" rev-parse HEAD)
git -C "$TMP/seed" remote add origin "$TMP/origin.git"
git -C "$TMP/seed" push -q origin main
git --git-dir="$TMP/origin.git" symbolic-ref HEAD refs/heads/main

git -C "$TMP/seed" switch -qc contributor
git -C "$TMP/seed" config user.name Contributor
git -C "$TMP/seed" config user.email contributor@example.com
printf 'contributor\n' >> "$TMP/seed/file"
# Deliberately bodyless: inherited contributor history must remain adoptable.
git -C "$TMP/seed" commit -qam 'Contributor change'
PR_HEAD=$(git -C "$TMP/seed" rev-parse HEAD)
git -C "$TMP/seed" push -q origin contributor:refs/heads/test-contributor
git --git-dir="$TMP/origin.git" update-ref refs/pull/7/head "$PR_HEAD"

git -C "$TMP/seed" switch -q main
git -C "$TMP/seed" config user.name Maintainer
git -C "$TMP/seed" config user.email maintainer@example.com
printf 'target\n' > "$TMP/seed/target"
git -C "$TMP/seed" add target
git -C "$TMP/seed" commit -qm 'Advance target branch' -m 'Create the exact target base used by the adoption fixture.'
BASE_HEAD=$(git -C "$TMP/seed" rev-parse HEAD)
git -C "$TMP/seed" push -q origin main

git clone -q "$TMP/origin.git" "$TMP/repo"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --arg head "${MOCK_HEAD:?}" --arg base "${MOCK_BASE:?}" --arg base_ref "${MOCK_BASE_REF:-main}" \
  '{head:{sha:$head,ref:"topic",repo:{full_name:"contributor/fork"}},base:{sha:$base,ref:$base_ref},
    user:{login:"contributor"},html_url:"https://example.invalid/pr/7"}'
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" MOCK_HEAD="$PR_HEAD" MOCK_BASE="$BASE_HEAD"

INPUT=$("$PREPARE" --repo "$TMP/repo" --pr 7 --work-bead fixture-adopt \
  --dest "$TMP/adopt" --branch adopt/pr-7/fixture --strategy merge)
jq -e --arg h "$PR_HEAD" --arg b "$BASE_HEAD" '
  .source_head_sha==$h and .target.sha==$b and .contributor.repository=="contributor/fork" and
  .strategy=="merge"' <<<"$INPUT" >/dev/null || fail 'pinned input lost provenance'
[ "$(git -C "$TMP/adopt" rev-parse HEAD)" = "$PR_HEAD" ] || fail 'continuation did not start at exact PR head'
[ "$(git -C "$TMP/adopt" symbolic-ref --short HEAD)" = adopt/pr-7/fixture ] || fail 'durable branch missing'

# Cancellation/retry is non-destructive: the exact same pinned continuation is
# reusable and a dirty/conflict-resolution checkpoint is not silently discarded.
printf 'checkpoint\n' > "$TMP/adopt/retry-state"
"$PREPARE" --repo "$TMP/repo" --pr 7 --work-bead fixture-adopt \
  --dest "$TMP/adopt" --branch adopt/pr-7/fixture --strategy merge >/dev/null
[ -f "$TMP/adopt/retry-state" ] || fail 'retry discarded dirty continuation state'
rm "$TMP/adopt/retry-state"

# A busy target branch may fast-forward after GitHub advertises the base. The
# freshly fetched tip, not the stale advertised snapshot, is the immutable pin.
git -C "$TMP/seed" switch -q main
printf 'newer target\n' >> "$TMP/seed/target"
git -C "$TMP/seed" commit -qam 'Advance target again' -m 'Model normal target movement after PR metadata was advertised.'
NEWER_BASE=$(git -C "$TMP/seed" rev-parse HEAD)
git -C "$TMP/seed" push -q origin main
FF_INPUT=$("$PREPARE" --repo "$TMP/repo" --pr 7 --work-bead fixture-fast-forward \
  --dest "$TMP/adopt-ff" --branch adopt/pr-7/fixture-ff --strategy merge)
[ "$(jq -r .target.sha <<<"$FF_INPUT")" = "$NEWER_BASE" ] || fail 'fast-forward did not pin the fetched target tip'
[ "$(jq -r .target.advertised_sha <<<"$FF_INPUT")" = "$BASE_HEAD" ] || fail 'advertised base provenance was lost'
[ "$(git -C "$TMP/adopt-ff" config --get gc.prAdopt.targetBase)" = "$NEWER_BASE" ] \
  || fail 'durable continuation did not pin the fetched target tip'
[ "$(git -C "$TMP/repo" rev-parse "$(jq -r .materialized_refs.base <<<"$FF_INPUT")")" = "$NEWER_BASE" ] \
  || fail 'materialized base ref did not pin the fetched target tip'

# Clean merge and rebase integrations must both contain the freshly fetched tip.
git -C "$TMP/adopt-ff" config user.name Maintainer
git -C "$TMP/adopt-ff" config user.email maintainer@example.com
git -C "$TMP/adopt-ff" merge --no-ff -q "$NEWER_BASE" -m 'Merge freshly fetched target tip' \
  -m 'Prove the merge result contains the exact immutable target tip.'
MERGE_RESULT=$(git -C "$TMP/adopt-ff" rev-parse HEAD)
[ "$(git -C "$TMP/adopt-ff" rev-parse HEAD^2)" = "$NEWER_BASE" ] || fail 'clean merge did not use fetched tip as a parent'
git -C "$TMP/adopt-ff" merge-base --is-ancestor "$NEWER_BASE" "$MERGE_RESULT" \
  || fail 'clean merge result does not contain fetched tip'

REBASE_INPUT=$("$PREPARE" --repo "$TMP/repo" --pr 7 --work-bead fixture-rebase \
  --dest "$TMP/adopt-rebase" --branch adopt/pr-7/fixture-rebase --strategy rebase)
[ "$(jq -r .target.sha <<<"$REBASE_INPUT")" = "$NEWER_BASE" ] || fail 'clean rebase input did not pin fetched tip'
GIT_EDITOR=true git -C "$TMP/adopt-rebase" rebase --onto "$NEWER_BASE" "$OLD_BASE" >/dev/null
git -C "$TMP/adopt-rebase" merge-base --is-ancestor "$NEWER_BASE" HEAD \
  || fail 'clean rebase result is not based on fetched tip'

# Conflicting merge and rebase paths use the same fetched-tip contract. A target
# move also makes an existing worktree retry fail instead of silently changing pins.
git -C "$TMP/seed" switch -q main
printf 'maintainer conflict\n' > "$TMP/seed/file"
git -C "$TMP/seed" commit -qam 'Create target-side conflict' -m 'Exercise conflict resolution against the fetched target tip.'
CONFLICT_BASE=$(git -C "$TMP/seed" rev-parse HEAD)
git -C "$TMP/seed" push -q origin main
if "$PREPARE" --repo "$TMP/repo" --pr 7 --work-bead fixture-fast-forward \
  --dest "$TMP/adopt-ff" --branch adopt/pr-7/fixture-ff --strategy merge >"$TMP/repin.out" 2>&1; then
  fail 'existing continuation silently accepted a newer target tip'
fi
grep -q 'existing continuation pins differ' "$TMP/repin.out" || fail 'retry pin drift lacked a clear failure'

CONFLICT_MERGE_INPUT=$("$PREPARE" --repo "$TMP/repo" --pr 7 --work-bead fixture-conflict-merge \
  --dest "$TMP/adopt-conflict-merge" --branch adopt/pr-7/conflict-merge --strategy merge)
[ "$(jq -r .target.sha <<<"$CONFLICT_MERGE_INPUT")" = "$CONFLICT_BASE" ] || fail 'conflicting merge did not pin fetched tip'
git -C "$TMP/adopt-conflict-merge" config user.name Maintainer
git -C "$TMP/adopt-conflict-merge" config user.email maintainer@example.com
if git -C "$TMP/adopt-conflict-merge" merge --no-ff "$CONFLICT_BASE" >/dev/null 2>&1; then
  fail 'merge conflict fixture unexpectedly merged cleanly'
fi
printf 'resolved merge\n' > "$TMP/adopt-conflict-merge/file"
git -C "$TMP/adopt-conflict-merge" add file
git -C "$TMP/adopt-conflict-merge" commit -qm 'Resolve target-tip merge conflict' -m 'Preserve the intended contributor behavior on the fetched target tip.'
git -C "$TMP/adopt-conflict-merge" merge-base --is-ancestor "$CONFLICT_BASE" HEAD \
  || fail 'conflict-resolved merge does not contain fetched tip'

CONFLICT_REBASE_INPUT=$("$PREPARE" --repo "$TMP/repo" --pr 7 --work-bead fixture-conflict-rebase \
  --dest "$TMP/adopt-conflict-rebase" --branch adopt/pr-7/conflict-rebase --strategy rebase)
[ "$(jq -r .target.sha <<<"$CONFLICT_REBASE_INPUT")" = "$CONFLICT_BASE" ] || fail 'conflicting rebase did not pin fetched tip'
if GIT_EDITOR=true git -C "$TMP/adopt-conflict-rebase" rebase --onto "$CONFLICT_BASE" "$OLD_BASE" >/dev/null 2>&1; then
  fail 'rebase conflict fixture unexpectedly rebased cleanly'
fi
printf 'resolved rebase\n' > "$TMP/adopt-conflict-rebase/file"
git -C "$TMP/adopt-conflict-rebase" add file
GIT_EDITOR=true git -C "$TMP/adopt-conflict-rebase" rebase --continue >/dev/null
git -C "$TMP/adopt-conflict-rebase" merge-base --is-ancestor "$CONFLICT_BASE" HEAD \
  || fail 'conflict-resolved rebase is not based on fetched tip'

# Rewritten target history fails closed even though the advertised snapshot still exists locally.
git -C "$TMP/seed" switch --orphan rewritten-main >/dev/null
git -C "$TMP/seed" rm -q -rf --ignore-unmatch .
printf 'rewritten\n' > "$TMP/seed/rewritten"
git -C "$TMP/seed" add rewritten
git -C "$TMP/seed" commit -qm 'Rewrite target history' -m 'Model a force-pushed target branch with unrelated history.'
git -C "$TMP/seed" push -q --force origin HEAD:main
if "$PREPARE" --repo "$TMP/repo" --pr 7 --work-bead rewritten --dest "$TMP/rewritten" \
  --branch adopt/pr-7/rewritten --strategy merge >"$TMP/rewritten.out" 2>&1; then
  fail 'rewritten target history was accepted'
fi
grep -q target-history-rewritten "$TMP/rewritten.out" || fail 'target rewrite lacked stable failure class'
[ ! -e "$TMP/rewritten" ] || fail 'target rewrite created a worktree'

# Merge the exact base and prove inherited bodyless contributor history is exempt
# while the workflow-authored merge remains subject to the quality gate.
git -C "$TMP/adopt" config user.name Maintainer
git -C "$TMP/adopt" config user.email maintainer@example.com
git -C "$TMP/adopt" merge --no-ff -q "$BASE_HEAD" -m 'Merge pinned target base' \
  -m 'Refresh the contributor change onto the exact reviewed target base.'
printf '[]\n' > "$TMP/checks.json"
jq -cn --argjson pr 7 --arg source "$PR_HEAD" --arg base "$BASE_HEAD" \
  --arg result "$(git -C "$TMP/adopt" rev-parse HEAD)" \
  '{schema:"pr-adoption-provenance.v1",source_pr:$pr,human_disposition_bead:"human-7",
    original_head_sha:$source,target_base_sha:$base,target_base_ref:"main",strategy:"merge",
    continuation_branch:"adopt/pr-7/fixture",resulting_head_sha:$result,
    original_commits:[],resulting_commits:[],recommended_upstream_action:"undecided",remote_mutation:false}' \
  > "$TMP/adoption.json"
"$EMIT" --repo "$TMP/adopt" --rig fixture --workflow pr-adopt --bead fixture-adopt \
  --intent pr_adopt --base "$BASE_HEAD" --branch adopt/pr-7/fixture \
  --verification-file "$TMP/checks.json" --adoption-file "$TMP/adoption.json" --output "$TMP/artifact.json"
jq -e --arg source "$PR_HEAD" '
  .producer.intent_kind=="pr_adopt" and .provenance.adoption.original_head_sha==$source and
  ([.commits[] | select(.inherited==true)] | length) >= 1' "$TMP/artifact.json" >/dev/null \
  || fail 'artifact did not preserve inherited provenance'

# A moved advertised head and unavailable target branch both fail before creating
# a continuation. The contributor fork name is metadata only; success above proves
# it is not needed or contacted.
git -C "$TMP/seed" switch -q contributor
printf 'moved\n' >> "$TMP/seed/file"
git -C "$TMP/seed" commit -qam 'Move contributor head' -m 'Create deterministic source-head drift for the test.'
MOVED=$(git -C "$TMP/seed" rev-parse HEAD)
git -C "$TMP/seed" push -q origin contributor:refs/heads/test-contributor
git --git-dir="$TMP/origin.git" update-ref refs/pull/7/head "$MOVED"
if "$PREPARE" --repo "$TMP/repo" --pr 7 --work-bead moved --dest "$TMP/moved" \
  --branch adopt/pr-7/moved --strategy merge >"$TMP/moved.out" 2>&1; then
  fail 'moved PR head was accepted'
fi
grep -q moved-head "$TMP/moved.out" || fail 'moved head lacked stable failure class'
[ ! -e "$TMP/moved" ] || fail 'moved head created a worktree'
export MOCK_HEAD="$MOVED" MOCK_BASE_REF=missing-branch
if "$PREPARE" --repo "$TMP/repo" --pr 7 --work-bead unavailable --dest "$TMP/unavailable" \
  --branch adopt/pr-7/unavailable --strategy merge >"$TMP/unavailable.out" 2>&1; then
  fail 'unavailable target branch was accepted'
fi
grep -q fetch-failed "$TMP/unavailable.out" || fail 'unavailable branch lacked stable failure class'
[ ! -e "$TMP/unavailable" ] || fail 'fetch failure created a worktree'

# Approval acts only on the internal adoption bead. The separately named human
# disposition bead is passed as provenance for revisions and is never mutated.
cat > "$TMP/bin/gc" <<'GC'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GC_LOG:?}"
while [ $# -gt 0 ]; do case "$1" in --city|--rig) shift 2;; *) break;; esac; done
case "${1-} ${2-}" in
  "bd show") jq -c '[.]' "${GC_STATE:?}" ;;
  "bd update")
    shift 3
    while [ $# -gt 0 ]; do
      case "$1" in
        --set-metadata) pair=$2; key=${pair%%=*}; value=${pair#*=};
          jq --arg k "$key" --arg v "$value" '.metadata[$k]=$v' "$GC_STATE" > "$GC_STATE.next";
          mv "$GC_STATE.next" "$GC_STATE"; shift 2 ;;
        --status) jq --arg v "$2" '.status=$v' "$GC_STATE" > "$GC_STATE.next";
          mv "$GC_STATE.next" "$GC_STATE"; shift 2 ;;
        *) shift ;;
      esac
    done ;;
  "bd close"|"mail send") : ;;
  *) printf 'unexpected gc: %s\n' "$*" >&2; exit 99 ;;
esac
GC
chmod +x "$TMP/bin/gc"
printf '%s\n' '{"schema":"pr-review.v1","verdict":"approve","has_disputed_major":false}' > "$TMP/approve.json"
printf '%s\n' '{"id":"internal-adopt","status":"open","metadata":{}}' > "$TMP/gc-state.json"
: > "$TMP/gc.log"
GC_BIN="$TMP/bin/gc" GC_LOG="$TMP/gc.log" GC_STATE="$TMP/gc-state.json" "$DECIDE" --rig fixture --work-bead internal-adopt \
  --intent pr_adopt --artifact-id artifact --head-sha "$PR_HEAD" --branch adopt/pr-7/fixture \
  --revision 1 --max-iterations 3 --synthesis-file "$TMP/approve.json" --feedback-bead review \
  --human-disposition-bead human-7 >/dev/null
grep -q 'bd close internal-adopt' "$TMP/gc.log" || fail 'internal adoption bead was not closed on approval'
! grep -q 'bd update human-7\|bd close human-7' "$TMP/gc.log" || fail 'human disposition bead was mutated'

grep -q 'max_attempts = 2' "$ROOT/dev-pack/formulas/pr-adopt.toml" || fail 'formula lost bounded retry'
printf 'pr adoption workflow: ok\n'
