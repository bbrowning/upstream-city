#!/usr/bin/env bash
# materialize — check out a PR (or any ref) into a durable, human-owned git
# worktree so a person can read, diff, and (env permitting) run its code AFTER
# an agent review has landed a verdict.
#
#   gc dev-pack materialize <PR-number | rig#PR | ref> [options]
#
# WHY THIS EXISTS: the reviewer/triage agents work in per-SLOT worktrees
# (.gc/worktrees/<rig>/<slot>) that are transient SCRATCH — a slot is reused
# across PRs, so once a review closes there is NO on-disk tree holding that PR's
# bits. This command re-materializes a PR into a PR-KEYED, human-namespaced
# worktree that lives OUTSIDE .gc/ (so `gc stop --clean` never reaps it) and is
# never touched by agent slot reuse. It is the durable companion to the reviewer's
# verdict + `dynamic_request` preview: the reviewer names the exact in-scope check
# it *would* run; this gives you a tree to run it in.
#
# Args:
#   <PR-number | rig#PR | ref>  a PR number N (fetched as origin pull/N/head),
#                       a rig-carrying PR alias, or any branch/tag/sha reachable
#                       via `git fetch origin <ref>`.
#
# Options:
#   --rig <name>    rig to materialize from             (default: vllm)
#   --base <ref>    diff baseline for the summary        (default: origin/main)
#   --force         re-create the worktree if it exists  (default: no-op/refuse)
#   --remove        remove the worktree for this PR/ref and exit
#   --json          machine-readable {path,rig,head_sha,base} instead of the
#                   human summary (used by `gc dev-pack ask` to get the path)
#   -h, --help      show this help
#
# Env (provided by gc): GC_CITY_PATH, GC_BIN. Optional override:
#   GC_MATERIALIZE_DIR   worktrees root (default: <city>/pr-worktrees)
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZE="$SCRIPT_DIR/../../assets/scripts/normalize-pr-target.sh"

RIG="vllm"
BASE="origin/main"
FORCE=0
REMOVE=0
JSONOUT=0
SPEC=""
RIG_EXPLICIT=0

usage() {
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --rig)     RIG="${2:?--rig needs a value}"; RIG_EXPLICIT=1; shift 2 ;;
        --rig=*)   RIG="${1#*=}"; RIG_EXPLICIT=1; shift ;;
        --base)    BASE="${2:?--base needs a value}"; shift 2 ;;
        --base=*)  BASE="${1#*=}"; shift ;;
        --force)   FORCE=1; shift ;;
        --remove)  REMOVE=1; shift ;;
        --json)    JSONOUT=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --)        shift; break ;;
        -*)        echo "materialize: unknown option '$1'" >&2; exit 2 ;;
        *)         if [ -z "$SPEC" ]; then SPEC="$1"; shift
                   else echo "materialize: unexpected argument '$1'" >&2; exit 2; fi ;;
    esac
done
[ $# -eq 0 ] || { [ -z "$SPEC" ] && SPEC="$1"; }

if [ -z "$SPEC" ]; then
    echo "materialize: missing <PR-number | rig#PR | ref>" >&2
    echo "usage: gc dev-pack materialize <PR-number | rig#PR | ref> [--rig N] [--base R] [--force] [--remove]" >&2
    exit 2
fi

[ -x "$NORMALIZE" ] || { echo "materialize: target normalizer not found/executable: $NORMALIZE" >&2; exit 2; }
NORM_ARGS=(--rig "$RIG")
[ "$RIG_EXPLICIT" -eq 1 ] && NORM_ARGS+=(--rig-explicit)
NORM=$("$NORMALIZE" "$SPEC" "${NORM_ARGS[@]}") || exit $?
SPEC=$(printf '%s' "$NORM" | jq -r '.spec')
RIG=$(printf '%s' "$NORM" | jq -r '.rig')

# --- Resolve the rig root the same way the fetch order does (no hardcoded path). -
RIGS_JSON=$("$GC" --city "$CITY" rig list --json 2>/dev/null) || {
    echo "materialize: could not list rigs — is '$CITY' a city?" >&2; exit 1; }
RIG_ROOT=$(printf '%s' "$RIGS_JSON" | jq -r --arg n "$RIG" \
    '.rigs[] | select(.name==$n) | .path' 2>/dev/null || true)
if [ -z "$RIG_ROOT" ] || [ ! -d "$RIG_ROOT/.git" ]; then
    echo "materialize: rig '$RIG' not found or not a git repo" >&2
    echo "materialize: known rigs: $(printf '%s' "$RIGS_JSON" | jq -r '.rigs[].name' 2>/dev/null | paste -sd, -)" >&2
    exit 1
fi

# --- PR number -> pull/N/head; anything else is treated as a ref. ------------
if printf '%s' "$SPEC" | grep -qE '^[0-9]+$'; then
    LABEL="pr-$SPEC"
    FETCHREF="pull/$SPEC/head"
else
    # Sanitize a branch/tag/sha into a filesystem-safe label.
    LABEL="ref-$(printf '%s' "$SPEC" | tr '/:' '__' | tr -cd 'A-Za-z0-9._-')"
    FETCHREF="$SPEC"
fi

WT_BASE="${GC_MATERIALIZE_DIR:-$CITY/pr-worktrees}"
WT_ROOT="$WT_BASE/$RIG"
DEST="$WT_ROOT/$LABEL"

# --- --remove: tear down this PR/ref's worktree and exit. -------------------
if [ "$REMOVE" -eq 1 ]; then
    git -C "$RIG_ROOT" worktree remove --force "$DEST" >/dev/null 2>&1 || rm -rf "$DEST"
    git -C "$RIG_ROOT" worktree prune >/dev/null 2>&1 || true
    if [ "$JSONOUT" -eq 1 ]; then
        jq -n --arg path "$DEST" '{removed: $path}'
    else
        echo "materialize: removed $DEST"
    fi
    exit 0
fi

# --- Fetch the target (read-only wrt working trees; updates refs + objects). --
echo "materialize: fetching $FETCHREF from origin (rig '$RIG')…" >&2
GIT_LFS_SKIP_SMUDGE=1 git -C "$RIG_ROOT" fetch --quiet origin "$FETCHREF"
SHA=$(git -C "$RIG_ROOT" rev-parse FETCH_HEAD)

print_summary() {
    local subj stat
    subj=$(git -C "$RIG_ROOT" log -1 --format='%s' "$SHA" 2>/dev/null || echo "(subject unavailable)")
    echo
    echo "PR/ref materialized for human review"
    echo "  rig:   $RIG  ($RIG_ROOT)"
    echo "  spec:  $SPEC  ->  $FETCHREF"
    echo "  head:  $SHA"
    echo "         $subj"
    echo "  base:  $BASE"
    echo "  path:  $DEST"
    echo
    echo "Changed files ($BASE...HEAD):"
    if stat=$(git -C "$RIG_ROOT" --no-pager diff --stat "$BASE...$SHA" 2>/dev/null) && [ -n "$stat" ]; then
        printf '%s\n' "$stat" | sed 's/^/  /'
    else
        echo "  (could not diff against '$BASE' — pass --base <ref> with a fetched baseline)"
    fi
    echo
    echo "Next:"
    echo "  cd $DEST"
    echo "  git diff $BASE...HEAD          # read the change"
    echo "  # then run the reviewer's suggested check — the dynamic_request.command"
    echo "  # from its pr-review.v1 verdict — right here in this tree."
    echo
    echo "Note: this materializes the CODE. Running vLLM's tests needs its build/venv,"
    echo "which this container does not carry — inspect/diff here; run where vLLM builds."
    echo
    echo "Remove when done:  gc dev-pack materialize $SPEC --rig $RIG --remove"
}

print_json() {
    jq -n --arg path "$DEST" --arg rig "$RIG" --arg head_sha "$SHA" --arg base "$BASE" \
        '{path: $path, rig: $rig, head_sha: $head_sha, base: $base}'
}

# --- Create, or update in place, the human-owned worktree. -------------------
if [ -e "$DEST/.git" ]; then
    cur=$(git -C "$DEST" rev-parse HEAD 2>/dev/null || echo "")
    if [ "$FORCE" -ne 1 ]; then
        if [ "$cur" = "$SHA" ]; then
            if [ "$JSONOUT" -eq 1 ]; then
                print_json
            else
                echo "materialize: already up to date at $DEST"
                print_summary
            fi
            exit 0
        fi
        echo "materialize: $DEST already exists at $cur," >&2
        echo "materialize: but $FETCHREF is now $SHA." >&2
        echo "materialize: re-run with --force to update it (discards any local changes there)." >&2
        exit 1
    fi
    git -C "$RIG_ROOT" worktree remove --force "$DEST" >/dev/null 2>&1 || rm -rf "$DEST"
    git -C "$RIG_ROOT" worktree prune >/dev/null 2>&1 || true
fi

mkdir -p "$WT_ROOT"
# Self-ignore the worktrees root inside the city repo so materialized trees never
# show up in the city's `git status`.
[ -f "$WT_BASE/.gitignore" ] || printf '*\n' > "$WT_BASE/.gitignore"

# stdout -> stderr: `git worktree add` prints a "Preparing worktree" progress
# line on stdout, which would otherwise contaminate --json output captured by
# callers like `gc dev-pack ask` (command substitution only captures stdout).
GIT_LFS_SKIP_SMUDGE=1 git -C "$RIG_ROOT" worktree add --detach "$DEST" "$SHA" 1>&2

# Point bd at the shared rig ledger (a fresh worktree has no tracked .beads/),
# and keep gascity/editor runtime files out of this worktree's `git status`.
mkdir -p "$DEST/.beads"
printf '%s\n' "$RIG_ROOT/.beads" > "$DEST/.beads/redirect"
EXCLUDE=$(git -C "$DEST" rev-parse --git-path info/exclude)
case "$EXCLUDE" in /*) ;; *) EXCLUDE="$DEST/$EXCLUDE" ;; esac
mkdir -p "$(dirname "$EXCLUDE")"
for p in ".beads/" ".gc/" ".claude/" "__pycache__/"; do
    grep -qxF "$p" "$EXCLUDE" 2>/dev/null || printf '%s\n' "$p" >> "$EXCLUDE"
done

if [ "$JSONOUT" -eq 1 ]; then
    print_json
else
    print_summary
fi
