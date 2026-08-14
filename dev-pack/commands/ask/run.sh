#!/usr/bin/env bash
# ask — follow up on an already-reviewed PR, in the PR's real code. Resolves the
# prior verdict (and every follow-up asked since) and materializes the PR into a
# durable worktree, then EITHER answers one question asynchronously (a question is
# given) OR drops you into a live interactive chat in that worktree (no question).
#
#   gc dev-pack ask <PR-number | bead-id> ["<question>"] [options]
#
#   gc dev-pack ask 51937 "why this refactor?"   # async: a one-shot agent mails the answer
#   gc dev-pack ask 51937                         # interactive: attach a live chat on this PR
#
# WHY THIS EXISTS: `gc dev-pack materialize` gets you the code, but reading a
# diff yourself is a scavenger hunt. Two shapes, same setup:
#   - ASYNC (question given): a one-shot agent answers ONE question from the real
#     code and mails it back — non-blocking, and each round sees every prior round
#     on this PR (see CONTINUITY). Best for fire-and-forget questions.
#   - INTERACTIVE (no question): opens a live agent session (`gc session new`,
#     which attaches your terminal), already cd'd into the PR worktree with the
#     verdict + prior Q&A loaded. One persistent chat PER PR: detach (Ctrl-b d)
#     while it thinks, hop to another PR, `gc dev-pack ask <PR>` to come back —
#     nothing blocks. Best for a back-and-forth deep dive.
#
# CONTINUITY: the async chain is anchored to the ROOT verdict bead via
# gc.followup_of; this command walks it, gathers every prior round's Q&A (oldest
# first), and writes it into the worktree as a context file the agent reads first,
# so a fresh async answer AND the first turn of an interactive chat both start
# warm. An interactive chat is otherwise EPHEMERAL: its back-and-forth lives only
# in the (persistent, re-attachable) session and is NOT written back into the
# async chain — run `ask <PR> "<question>"` for a durable, mailed, chained answer.
#
# Args:
#   <PR-number | bead-id>  a PR number N (resolved to its newest verdict bead),
#                          or any bead id in the review/follow-up chain (a
#                          verdict bead, or an earlier follow-up bead — both
#                          resolve to the same root).
#   <question>             OPTIONAL. Given -> async one-shot answer by mail.
#                          Omitted -> interactive chat session (needs a terminal).
#
# Options:
#   --rig <name>   rig the PR belongs to              (default: vllm)
#   --base <ref>   diff baseline, passed to materialize (default: origin/main)
#   --force        force-refresh the worktree if the PR head has moved
#                  (discards local changes there — passthrough to materialize)
#   --dry-run      print what would run without running it
#   -h, --help     show this help
#
# Env (provided by gc): GC_CITY_PATH, GC_RIG, GC_BIN.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$SCRIPT_DIR/../../assets/scripts/resolve-verdict-bead.sh"
MATERIALIZE="$SCRIPT_DIR/../materialize/run.sh"

RIG="vllm" ; BASE="origin/main" ; SPEC="" ; QUESTION="" ; FORCE=0 ; DRYRUN=0 ; INTERACTIVE=0

usage() {
    sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'
}
die() { printf '%s\n' "ask: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)     RIG="${2:?--rig needs a value}"; shift 2 ;;
        --rig=*)   RIG="${1#*=}"; shift ;;
        --base)    BASE="${2:?--base needs a value}"; shift 2 ;;
        --base=*)  BASE="${1#*=}"; shift ;;
        --force)   FORCE=1; shift ;;
        --dry-run) DRYRUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --)        shift
                   for a in "$@"; do
                       if [ -z "$SPEC" ]; then SPEC="$a"
                       elif [ -z "$QUESTION" ]; then QUESTION="$a"
                       else die "unexpected argument '$a'"; fi
                   done
                   break ;;
        -*)        die "unknown option '$1'" ;;
        *)         if [ -z "$SPEC" ]; then SPEC="$1"; shift
                   elif [ -z "$QUESTION" ]; then QUESTION="$1"; shift
                   else die "unexpected argument '$1'"; fi ;;
    esac
done
# No question -> interactive chat session (drop into a live agent on this PR).
[ -n "$SPEC" ] || { usage >&2; die "missing <PR-number | bead-id>"; }
[ -n "$QUESTION" ] || INTERACTIVE=1
[ -x "$RESOLVE" ] || die "resolver not found/executable: $RESOLVE"
[ -x "$MATERIALIZE" ] || die "materialize script not found/executable: $MATERIALIZE"

# --- 1. Resolve the ROOT verdict bead (PR number, verdict bead, or a follow-up
#        bead anywhere in the chain — resolve-verdict-bead.sh walks up to root).
ROOT=$("$RESOLVE" "$SPEC" --rig "$RIG") || exit $?

ROOT_SHOW=$("$GC" --city "$CITY" --rig "$RIG" bd show "$ROOT" --json 2>/dev/null) \
    || die "could not read root bead '$ROOT' in rig '$RIG' (city '$CITY')"
ROOT_VJSON=$(printf '%s' "$ROOT_SHOW" | jq -r '.[0].metadata["gc.output_json"] // empty')
[ -n "$ROOT_VJSON" ] || die "root bead '$ROOT' has no gc.output_json verdict — not a finished review?"
HEAD_REF=$(printf '%s' "$ROOT_VJSON" | jq -r '.head_ref // empty')
[ -n "$HEAD_REF" ] || die "root bead '$ROOT' verdict has no head_ref — cannot materialize"

printf 'ask: PR/ref %s -> root verdict bead %s\n' "$HEAD_REF" "$ROOT" >&2

# --- 2. Gather every prior follow-up round on this root, oldest first. -------
PRIOR_JSON=$("$GC" --city "$CITY" --rig "$RIG" bd list --all --json \
    --metadata-field "gc.followup_of=$ROOT" -n 0 2>/dev/null || printf '[]')
PRIOR_QA=$(printf '%s' "$PRIOR_JSON" | jq '
    [ .[]?
      | . as $b
      | ($b.metadata["gc.output_json"] // "" | fromjson?) as $vj
      | select($vj != null)
      | {ts: ($b.closed_at // $b.updated_at // $b.created_at // ""),
         question: ($vj.question // ""), answer: ($vj.answer // "")} ]
    | sort_by(.ts)')
ROUND_COUNT=$(printf '%s' "$PRIOR_QA" | jq 'length')
printf 'ask: %s prior follow-up round(s) found for this PR\n' "$ROUND_COUNT" >&2

MAT_ARGS=(--rig "$RIG" --base "$BASE" --json)
[ "$FORCE" -eq 1 ] && MAT_ARGS+=(--force)

if [ "$DRYRUN" -eq 1 ]; then
    printf 'DRY RUN — would run:\n  %s' "$MATERIALIZE"
    for a in "$HEAD_REF" "${MAT_ARGS[@]}"; do printf ' %q' "$a"; done
    if [ "$INTERACTIVE" -eq 1 ]; then
        printf '\nDRY RUN — would write rendezvous:\n  %s\n' \
            "$CITY/.gc/dev-pack/pr-chat/$RIG/pr-$HEAD_REF.json"
        printf 'DRY RUN — would then attach an interactive chat for PR %s in rig %s\n' \
            "$HEAD_REF" "$RIG"
        printf '  (reuse existing pr-chat-%s if live, else: gc session new %s/pr-chat --alias pr-chat-%s)\n' \
            "$HEAD_REF" "$RIG" "$HEAD_REF"
    else
        printf '\nDRY RUN — would then sling pr-followup for PR %s in rig %s with question:\n  %s\n' \
            "$HEAD_REF" "$RIG" "$QUESTION"
    fi
    exit 0
fi

# --- 3. Ensure a durable, PR-keyed worktree exists (reuse materialize as-is). -
MAT_JSON=$("$MATERIALIZE" "$HEAD_REF" "${MAT_ARGS[@]}") \
    || die "materialize failed for '$HEAD_REF' — see above. Pass --force to override a stale worktree."
WORKTREE=$(printf '%s' "$MAT_JSON" | jq -r '.path // empty')
[ -n "$WORKTREE" ] || die "materialize did not report a worktree path (unexpected --json output: $MAT_JSON)"

# --- 4. Render the context file (verdict recap + every prior Q&A) into the ---
#        worktree, untracked, so the fresh agent can `cat` it and isn't cold.
CONTEXT_REL=".dev-pack-followup-context.md"
CONTEXT_FILE="$WORKTREE/$CONTEXT_REL"
{
    printf '# Prior context for PR %s\n\n' "$HEAD_REF"
    printf '## Original review verdict (bead %s)\n\n' "$ROOT"
    printf '%s' "$ROOT_VJSON" | jq -r '
        "- verdict: \(.verdict // "n/a")",
        "- findings_count: \(.findings_count // 0)",
        "- summary: \(.summary // "(none)")"
    '
    printf '\n'
    if [ "$ROUND_COUNT" -gt 0 ]; then
        printf '## Follow-up rounds so far (oldest first)\n\n'
        printf '%s' "$PRIOR_QA" | jq -r '
            to_entries[] | "### Round \(.key + 1)\n\nQ: \(.value.question)\n\nA:\n\(.value.answer)\n"'
    fi
} > "$CONTEXT_FILE"

# Keep the context file (and other gascity/editor runtime dirs) out of this
# worktree's `git status` — same trick materialize already uses.
EXCLUDE=$(git -C "$WORKTREE" rev-parse --git-path info/exclude)
case "$EXCLUDE" in /*) ;; *) EXCLUDE="$WORKTREE/$EXCLUDE" ;; esac
mkdir -p "$(dirname "$EXCLUDE")"
grep -qxF "$CONTEXT_REL" "$EXCLUDE" 2>/dev/null || printf '%s\n' "$CONTEXT_REL" >> "$EXCLUDE"

# --- 5a. ASYNC (question given): sling the one-shot follow-up agent. ----------
if [ "$INTERACTIVE" -eq 0 ]; then
    printf 'ask: slinging follow-up for PR %s in rig %s\n' "$HEAD_REF" "$RIG" >&2
    exec "$GC" --city "$CITY" --rig "$RIG" sling "$RIG/pr-follow-up" pr-followup --formula \
        --var "pr=$HEAD_REF" --var "base_ref=$BASE" --var "question=$QUESTION" \
        --var "worktree_path=$WORKTREE" --var "root_bead=$ROOT" --var "context_file=$CONTEXT_FILE" \
        --title "follow-up: PR $HEAD_REF" --json
fi

# --- 5b. INTERACTIVE (no question): drop into a live per-PR chat session. -----
# Attaching hands this terminal to the agent (blocks until you detach), so bail
# early if there is no TTY rather than leaving a half-created session behind.
{ [ -t 0 ] && [ -t 1 ]; } || \
    die "interactive mode needs a terminal. Pass a \"<question>\" for the async path, or run from a terminal."

# Rendezvous file: the ONLY per-PR channel into the session — `gc session new`
# takes no --work-dir/--var/--initial-message, and ambient env doesn't reach the
# tmux pane. The pr-chat agent reads this on its first turn (path derived from
# $GC_CITY_PATH + $GC_RIG + the PR number in its own $GC_ALIAS).
ALIAS="pr-chat-$HEAD_REF"
RENDEZVOUS="$CITY/.gc/dev-pack/pr-chat/$RIG/pr-$HEAD_REF.json"
mkdir -p "$(dirname "$RENDEZVOUS")"
jq -n --arg pr "$HEAD_REF" --arg base "$BASE" --arg wt "$WORKTREE" \
      --arg ctx "$CONTEXT_FILE" --arg root "$ROOT" \
  '{pr:$pr, base_ref:$base, worktree_path:$wt, context_file:$ctx, root_bead:$root}' \
  > "$RENDEZVOUS"

# One persistent chat PER PR: reuse a live/suspended one if it exists (attach
# resumes it with full history), else create fresh (session new attaches by
# default). Match on the alias suffix — gascity may qualify the stored alias.
EXISTING=$("$GC" --city "$CITY" session list --template "$RIG/pr-chat" --state all --json 2>/dev/null \
    | jq -r --arg a "$ALIAS" '(if type=="array" then . else .sessions end) | [ .[]?
        | select((.alias // "") | endswith($a))
        | select(.state == "active" or .state == "suspended") | .id ][0] // empty')

if [ -n "$EXISTING" ]; then
    printf 'ask: resuming interactive chat for PR %s (%s)\n' "$HEAD_REF" "$EXISTING" >&2
    exec "$GC" --city "$CITY" session attach "$EXISTING"
else
    printf 'ask: opening interactive chat for PR %s in rig %s\n' "$HEAD_REF" "$RIG" >&2
    exec "$GC" --city "$CITY" --rig "$RIG" session new "$RIG/pr-chat" \
        --alias "$ALIAS" --title "PR chat: $RIG PR $HEAD_REF"
fi
