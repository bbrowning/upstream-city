#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Build a self-contained copy of ask with deterministic resolver/materializer
# dependencies. This lets the test exercise the real control flow without a
# network fetch or a live session.
PACK="$TMP/dev-pack"
mkdir -p "$PACK/commands/ask" "$PACK/commands/materialize" "$PACK/assets/scripts" "$TMP/worktree"
cp "$ROOT/dev-pack/commands/ask/run.sh" "$PACK/commands/ask/run.sh"
cp "$ROOT/dev-pack/assets/scripts/normalize-pr-target.sh" "$PACK/assets/scripts/normalize-pr-target.sh"
cp "$ROOT/dev-pack/assets/scripts/resolve-verdict-bead.sh" "$PACK/assets/scripts/resolve-verdict-bead.sh"
git -C "$TMP/worktree" init -q

cat > "$PACK/commands/materialize/run.sh" <<'MATERIALIZE'
#!/usr/bin/env bash
printf 'materialized\n' >> "${GC_TEST_LOG:?}"
jq -cn --arg path "${GC_TEST_WORKTREE:?}" '{path:$path}'
MATERIALIZE
chmod +x "$PACK/commands/materialize/run.sh"

cat > "$TMP/gc" <<'GC'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GC_TEST_LOG:?}"
args=" $* "
if [[ "$args" == *" rig list --json "* ]]; then
    printf '%s\n' '{"rigs":[{"name":"vllm","path":"/tmp/vllm"}]}'
elif [[ "$args" == *" bd list "* && "$args" == *"gc.followup_of="* ]]; then
    printf '%s\n' '[]'
elif [[ "$args" == *" bd list "* ]]; then
    jq -cn '[{id:"vllm-root",closed_at:"2026-08-25T00:00:00Z",close_reason:"review: approve",metadata:{"gc.output_json_schema":"pr-review.v1","gc.output_json":"{\"head_ref\":\"53174\",\"verdict\":\"approve\",\"findings_count\":0,\"summary\":\"ok\"}"}}]'
elif [[ "$args" == *" bd show vllm-root --json "* ]]; then
    jq -cn '[{id:"vllm-root",metadata:{"gc.output_json":"{\"head_ref\":\"53174\",\"verdict\":\"approve\",\"findings_count\":0,\"summary\":\"ok\"}"}}]'
elif [[ "$args" == *" session list "* ]]; then
    printf '%s\n' '[]'
elif [[ "$args" == *" session new "* ]]; then
    printf '%s\n' 'attached'
else
    printf 'unexpected gc call: %s\n' "$*" >&2
    exit 99
fi
GC
chmod +x "$TMP/gc"

export GC_BIN="$TMP/gc"
export GC_CITY_PATH="$TMP/city"
export GC_TEST_LOG="$TMP/gc.log"
export GC_TEST_WORKTREE="$TMP/worktree"
mkdir -p "$GC_CITY_PATH"

# A headless call must fail before resolver or materializer work begins.
: > "$GC_TEST_LOG"
if "$PACK/commands/ask/run.sh" 53174 </dev/null >"$TMP/headless.out" 2>&1; then
    fail 'headless interactive ask unexpectedly succeeded'
fi
grep -q 'interactive mode needs a terminal' "$TMP/headless.out" \
    || fail "headless failure lacked terminal guidance: $(cat "$TMP/headless.out")"
[ ! -s "$GC_TEST_LOG" ] \
    || fail "headless ask did work before its terminal check: $(cat "$GC_TEST_LOG")"

# gc proxies a pack command's stdout, so model the production descriptor shape:
# stdin is a PTY while stdout is a pipe. Interactive ask must accept this.
command -v script >/dev/null 2>&1 || fail "the 'script' PTY utility is required"
: > "$GC_TEST_LOG"
quoted_ask=$(printf '%q' "$PACK/commands/ask/run.sh")
if ! script -qefc "$quoted_ask 53174 | cat" /dev/null >"$TMP/pty.out" 2>&1; then
    fail "interactive ask with piped stdout failed: $(cat "$TMP/pty.out")"
fi
grep -q 'session new vllm/pr-chat' "$GC_TEST_LOG" \
    || fail "interactive ask never opened the chat: $(cat "$GC_TEST_LOG")"
grep -q '^materialized$' "$GC_TEST_LOG" \
    || fail "interactive ask never materialized the worktree: $(cat "$GC_TEST_LOG")"
! grep -q 'interactive mode needs a terminal' "$TMP/pty.out" \
    || fail "piped stdout was incorrectly rejected: $(cat "$TMP/pty.out")"

printf '%s\n' 'ok: dev-pack ask interactive terminal detection'
