#!/bin/sh
# worktree-setup.sh — create an isolated, DETACHED git worktree for one pool
# slot, so N agents on the same rig never share a checkout.
#
# SHARED SPINE SCRIPT. This is the single canonical copy for every dev-lane
# pack (PR review, hard-bug, feature-dev). Agents reference it from pre_start
# via the city-root path:
#
#   pre_start = ["{{.CityRoot}}/tools/shared/worktree-setup.sh {{.RigRoot}} {{.WorkDir}} {{.AgentBase}}"]
#
# The three args are template-expanded by gascity from the pre_start line:
#   {{.RigRoot}}  {{.WorkDir}}  {{.AgentBase}}
#
# WHY DETACHED: git refuses to check out a *branch* that is already checked out
# in another worktree, but detached worktrees have no such exclusivity. So N
# slots can each sit at a different sha (or even the same one) with zero
# conflict. A read-only lane checks out its target ref itself; a write lane
# creates its own branch as its first step. pre_start only has to guarantee the
# *isolation*, not the job-specific checkout (it has no per-bead context anyway).
#
# WHY THE STAGING DANCE: gascity stages runtime files (notably
# `.gc/settings.json`) INTO the work_dir *before* pre_start runs, so the target
# is already non-empty when we get here. `git worktree add` refuses a non-empty
# target ("fatal: '<dir>' already exists"), which is a fatal pre_start error and
# crash-loops the session. So we move the pre-staged files aside, create the
# worktree into the now-empty dir, then restore the staged files on top. This
# matches the shipping examples/lifecycle/.../worktree-setup.sh; we differ only
# by using a DETACHED worktree instead of a persistent `gc-<agent>` branch.

set -eu

RIG_ROOT="${1:?usage: worktree-setup.sh <rig-root> <target-dir> <agent-base>}"
WT="${2:?missing target worktree dir}"
AGENT="${3:?missing agent base name}"

# Claude Code keeps workspace trust per exact working-directory path in the
# user's state file.  Pool workers run unattended, so a newly-created worktree
# cannot answer Claude's interactive trust prompt and will otherwise crash-loop
# before the session becomes ready.  Trust only Gas City-managed worktrees for
# this city; never bless an arbitrary path supplied as WT.
trust_managed_worktree_for_claude() {
    [ -n "${GC_CITY_PATH:-}" ] || return 0
    command -v jq >/dev/null 2>&1 || {
        echo "worktree-setup: jq is required to register Claude workspace trust" >&2
        return 1
    }
    command -v flock >/dev/null 2>&1 || {
        echo "worktree-setup: flock is required to register Claude workspace trust" >&2
        return 1
    }

    CITY_ROOT_ABS=$(cd "$GC_CITY_PATH" 2>/dev/null && pwd -P || echo "$GC_CITY_PATH")
    case "$WT_ABS" in
        "$CITY_ROOT_ABS"/.gc/worktrees/*) ;;
        *)
            echo "worktree-setup: refusing to trust non-managed Claude path: $WT_ABS" >&2
            return 1
            ;;
    esac

    CLAUDE_STATE="${HOME:?HOME is required}/.claude.json"
    CLAUDE_LOCK="$CLAUDE_STATE.gascity.lock"
    (
        umask 077
        flock -x 9
        CLAUDE_TMP=$(mktemp "$CLAUDE_STATE.gascity.XXXXXX")
        trap 'rm -f "$CLAUDE_TMP"' EXIT HUP INT TERM
        if [ -s "$CLAUDE_STATE" ]; then
            jq --arg project "$WT_ABS" '
                .projects = ((.projects // {}) |
                    .[$project] = ((.[$project] // {}) +
                        {"hasTrustDialogAccepted": true}))
            ' "$CLAUDE_STATE" > "$CLAUDE_TMP"
        else
            jq -n --arg project "$WT_ABS" '
                {"projects": {($project): {"hasTrustDialogAccepted": true}}}
            ' > "$CLAUDE_TMP"
        fi
        chmod 600 "$CLAUDE_TMP"
        mv "$CLAUDE_TMP" "$CLAUDE_STATE"
        trap - EXIT HUP INT TERM
    ) 9>"$CLAUDE_LOCK"
}

# --- Safety guard: never operate on the rig root itself. --------------------
# The rig root is a shared working checkout that also hosts the rig's .beads DB;
# nobody should ever *work* in it. If work_dir is missing/misconfigured it
# resolves straight to the rig root (gascity default) — so fail LOUDLY here
# instead of silently letting an agent stomp the shared checkout. This is the
# guarantee a bare mirror would otherwise give us, without going bare.
RIG_ROOT_ABS=$(cd "$RIG_ROOT" 2>/dev/null && pwd -P || echo "$RIG_ROOT")
WT_ABS=$(cd "$WT" 2>/dev/null && pwd -P || echo "$WT")
if [ "$WT_ABS" = "$RIG_ROOT_ABS" ]; then
    echo "worktree-setup: REFUSING — target ($WT) is the rig root itself." >&2
    echo "worktree-setup: work_dir is missing or misconfigured for agent '$AGENT'." >&2
    exit 1
fi

# This must precede the reuse fast-path: a worktree may already exist from a
# failed Claude launch that stopped at the trust dialog.
trust_managed_worktree_for_claude

# --- Idempotent: reuse an existing worktree, never clobber in-flight work. ---
# gascity preserves worktrees across restarts on purpose (crash recovery). If the
# slot's worktree already exists (a real .git pointer), leave it as-is and
# succeed.
if [ -e "$WT/.git" ]; then
    exit 0
fi

mkdir -p "$(dirname "$WT")"

# --- Staging dance: move any pre-staged files aside so the dir is empty. -----
# gascity may have already dropped `.gc/settings.json` (and friends) into $WT;
# `git worktree add` requires an empty/absent target. We stash those files in a
# sibling temp dir, create the worktree, then merge them back on top.
STAGE=""

merge_stage_entry() {
    # SRC/DST/ENTRY must be local: this function recurses, and a sibling's
    # recursive call clobbering the parent's $DST/$SRC (plain globals) misdirects
    # later siblings' merges and the trailing rmdir — see wo-4yi6.
    local SRC="$1"
    local DST="$2"

    if [ -d "$SRC" ]; then
        mkdir -p "$DST"
        local ENTRY
        for ENTRY in "$SRC"/.[!.]* "$SRC"/..?* "$SRC"/*; do
            [ -e "$ENTRY" ] || continue
            merge_stage_entry "$ENTRY" "$DST/$(basename "$ENTRY")"
        done
        rmdir "$SRC" 2>/dev/null || true
        return 0
    fi

    # Never clobber a file git wrote into the worktree.
    if [ -e "$DST" ]; then
        return 0
    fi
    mv "$SRC" "$DST"
}

restore_stage() {
    [ -n "$STAGE" ] || return 0
    mkdir -p "$WT"
    for ENTRY in "$STAGE"/.[!.]* "$STAGE"/..?* "$STAGE"/*; do
        [ -e "$ENTRY" ] || continue
        merge_stage_entry "$ENTRY" "$WT/$(basename "$ENTRY")"
    done
    rmdir "$STAGE" 2>/dev/null || true
    STAGE=""
}

if [ -d "$WT" ] && [ "$(find "$WT" -mindepth 1 -maxdepth 1 | head -n 1)" ]; then
    STAGE=$(mktemp -d "$(dirname "$WT")/.gascity-worktree-stage.XXXXXX")
    find "$WT" -mindepth 1 -maxdepth 1 -exec mv {} "$STAGE"/ \;
    # If anything below fails, put the staged files back so we don't strand the
    # agent's settings in a temp dir.
    trap 'restore_stage' EXIT HUP INT TERM
fi

rmdir "$WT" 2>/dev/null || true

# --- Create a detached worktree at the rig's current HEAD. ------------------
# Objects are shared with the rig root, so only the working tree is written.
# The initial detach point barely matters: the agent fetches + checks out its
# real target ref as step 1.
if ! GIT_LFS_SKIP_SMUDGE=1 git -C "$RIG_ROOT" worktree add --detach "$WT" HEAD; then
    echo "worktree-setup: failed to create detached worktree at $WT from $RIG_ROOT" >&2
    restore_stage
    exit 1
fi

# Restore the pre-staged files on top of the fresh worktree (settings.json etc).
restore_stage
trap - EXIT HUP INT TERM

# --- Point beads at the shared rig store (filesystem-bead redirect). --------
# A fresh worktree has no .beads/ (it is not part of the tracked tree), so bd
# run from inside the worktree would not find the rig's ledger without this.
mkdir -p "$WT/.beads"
printf '%s\n' "$RIG_ROOT/.beads" > "$WT/.beads/redirect"

# --- Keep gascity runtime files out of `git status` without mutating the -----
# --- tracked .gitignore (matches the shipping worktree-setup.sh). -----------
EXCLUDE=$(git -C "$WT" rev-parse --git-path info/exclude)
case "$EXCLUDE" in /*) ;; *) EXCLUDE="$WT/$EXCLUDE" ;; esac
mkdir -p "$(dirname "$EXCLUDE")"
for p in ".gc/" ".beads/redirect" ".beads/hooks/" ".beads/formulas/" ".logs/" \
         ".claude/" ".codex/" ".gemini/" "__pycache__/" ".venv/" ".pytest_cache/"; do
    grep -qxF "$p" "$EXCLUDE" 2>/dev/null || printf '%s\n' "$p" >> "$EXCLUDE"
done

exit 0
