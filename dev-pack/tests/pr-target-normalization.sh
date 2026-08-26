#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/gc" <<'GC'
#!/usr/bin/env bash
args=" $* "
if [[ "$args" == *" rig list --json "* ]]; then
    printf '%s\n' '{"rigs":[{"name":"vllm","path":"/tmp/vllm"},{"name":"paude","path":"/tmp/paude"}]}'
elif [[ "$args" == *" agent list "* ]]; then
    printf '%s\n' 'vllm/pr-review-synthesizer' 'vllm/pr-reviewer-gpt56luna-xhigh' 'vllm/pr-arbiter'
elif [[ "$args" == *" bd list "* && "$args" == *"gc.followup_of="* ]]; then
    printf '%s\n' '[]'
elif [[ "$args" == *" bd list "* ]]; then
    jq -cn '[{id:"vllm-root",closed_at:"2026-08-25T00:00:00Z",close_reason:"review: approve",metadata:{"gc.root_bead_id":"vllm-run","gc.output_json_schema":"pr-review.v1","gc.output_json":"{\"schema\":\"pr-review.v1\",\"head_ref\":\"vllm#53174\",\"base_ref\":\"origin/main\",\"verdict\":\"approve\",\"findings_count\":0,\"summary\":\"ok\"}"}}]'
elif [[ "$args" == *" bd show vllm-root --json "* ]]; then
    jq -cn '[{id:"vllm-root",metadata:{"gc.root_bead_id":"vllm-run","gc.output_json_schema":"pr-review.v1","gc.output_json":"{\"schema\":\"pr-review.v1\",\"head_ref\":\"vllm#53174\",\"base_ref\":\"origin/main\",\"verdict\":\"approve\",\"findings_count\":0,\"summary\":\"ok\"}"}}]'
elif [[ "$args" == *" bd show vllm-step --json "* ]]; then
    line=$(grep 'bd update vllm-step --set-metadata gc.output_json=' "${GC_TEST_LOG:?}" | tail -n 1)
    out=${line#*gc.output_json=}; out=${out% --set-metadata gc.outcome=*}
    outcome=${line##*gc.outcome=}; outcome=${outcome%% *}
    jq -cn --arg out "$out" --arg outcome "$outcome" \
      '[{id:"vllm-step",metadata:{"gc.output_json":$out,"gc.outcome":$outcome}}]'
elif [[ "$args" == *" bd update "* || "$args" == *" bd close "* ]]; then
    printf '%s\n' "$*" >> "${GC_TEST_LOG:?}"
else
    printf 'unexpected gc call: %s\n' "$*" >&2
    exit 99
fi
GC
chmod +x "$TMP/gc"

export GC_BIN="$TMP/gc"
export GC_CITY_PATH="$ROOT"
NORMALIZE="$ROOT/dev-pack/assets/scripts/normalize-pr-target.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_fail() {
    local pattern="$1"; shift
    local out
    if out=$("$@" 2>&1); then fail "command unexpectedly succeeded: $*"; fi
    [[ "$out" == *"$pattern"* ]] || fail "failure did not contain '$pattern': $out"
}

alias_json=$("$NORMALIZE" 'vllm#53174')
[ "$(printf '%s' "$alias_json" | jq -r '.spec,.rig,.is_pr,.was_alias' | paste -sd, -)" = \
  '53174,vllm,true,true' ] || fail "valid alias was not canonicalized: $alias_json"
expect_fail "conflicts with --rig 'paude'" "$NORMALIZE" 'vllm#53174' --rig paude --rig-explicit
expect_fail "unknown rig 'missing'" "$NORMALIZE" 'missing#53174'
for bad in 'vllm#' '#53174' 'vllm#abc' 'vllm#1#2' 'vllm#53174;touch-pwned' 'vllm$(id)#53174'; do
    expect_fail 'malformed rig#PR' "$NORMALIZE" "$bad"
done

alias_review=$("$ROOT/dev-pack/commands/review/run.sh" 'vllm#53174' --dry-run)
explicit_review=$("$ROOT/dev-pack/commands/review/run.sh" 53174 --rig vllm --dry-run)
[ "$alias_review" = "$explicit_review" ] || fail "review alias and explicit forms differ"
[[ "$alias_review" == *'head_ref=53174'* ]] || fail "canonical head_ref missing from review dry run"
[[ "$alias_review" != *'vllm#53174'* ]] || fail "compound alias leaked into review dry run"

# Defensive execution boundaries also strip the alias before choosing GitHub
# mode. gh is stubbed just far enough to prove prescan receives bare 53174.
cat > "$TMP/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
    'pr diff') [ "$3" = 53174 ] || exit 88; printf '%s\n' 'diff --git a/a.md b/a.md' '+++ b/a.md' '+safe' ;;
    'pr view') [ "$3" = 53174 ] || exit 88; printf '%s\n' '{"files":[{"path":"a.md"}]}' ;;
    'api repos/{owner}/{repo}/pulls/53174') printf '%s\n' '{"author_association":"MEMBER","user":{"login":"trusted"}}' ;;
    *) exit 88 ;;
esac
GH
chmod +x "$TMP/gh"
PATH="$TMP:$PATH" GC_RIG=vllm "$ROOT/dev-pack/assets/scripts/pr-prescan.sh" 'vllm#53174' \
    | jq -e '.head_ref == "53174" and .source == "gh-pr"' >/dev/null \
    || fail "prescan did not canonicalize before source selection"

# Exact handoff regression: bare ask resolves a historical verdict containing
# head_ref=vllm#53174, but hands materialize the bare PR plus the selected rig.
ask_out=$("$ROOT/dev-pack/commands/ask/run.sh" 53174 'why?' --dry-run 2>&1)
[[ "$ask_out" == *'PR/ref 53174 -> root verdict bead vllm-root'* ]] \
    || fail "ask did not canonicalize legacy verdict: $ask_out"
[[ "$ask_out" == *'materialize/run.sh 53174 --rig vllm'* ]] \
    || fail "ask did not hand canonical PR/rig to materialize: $ask_out"
[[ "$ask_out" != *'PR/ref vllm#53174'* ]] || fail "legacy compound ref leaked from ask"

summary_out=$("$ROOT/dev-pack/commands/summary/run.sh" 53174 2>&1)
[[ "$summary_out" == *'PR 53174 · APPROVE'* ]] \
    || fail "summary did not render the canonical legacy head: $summary_out"
[[ "$summary_out" != *'vllm#53174'* ]] || fail "legacy compound ref leaked into summary"

# Agent output is another handoff boundary: persist a canonical head even if a
# legacy/errant producer emits the compound form.
printf '%s\n' '{"schema":"pr-review.v1","head_ref":"vllm#53174","verdict":"approve","findings_count":0}' \
    > "$TMP/verdict.json"
export GC_TEST_LOG="$TMP/gc.log"
: > "$GC_TEST_LOG"
GC_RIG=vllm GC_PR_NOTIFY_TO='' "$ROOT/dev-pack/assets/scripts/emit-verdict.sh" \
    --bead vllm-step --verdict-file "$TMP/verdict.json" --outcome pass
grep -q '"head_ref":"53174"' "$GC_TEST_LOG" \
    || fail "emit-verdict did not persist canonical head_ref: $(cat "$GC_TEST_LOG")"
! grep -q 'vllm#53174' "$GC_TEST_LOG" \
    || fail "emit-verdict persisted a compound head_ref"

printf '%s\n' 'ok: dev-pack PR target normalization'
