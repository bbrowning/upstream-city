#!/usr/bin/env bash
# Claude Code Stop hook -> auto-capture arena decisions.
#
# Wired from ~/.claude/settings.json (hooks.Stop). It fires when ANY Claude Code
# session ends, including the gascity agent sessions (they run as normal CLI sessions
# under the default ~/.claude config dir, so user hooks apply). We must stay cheap for
# the common case, so we only do work when a *coordinator* worktree session ends — the
# session that just wrote an N>=2 reconcile decision, with all worker transcripts fresh.
#
# For matching sessions we launch arena_refresh.py DETACHED (setsid, backgrounded) so we
# never add latency to gascity's session teardown; transcripts live in ~/.claude/projects
# (not the worktree) so they survive the worktree being reclaimed. Always exit 0 — a Stop
# hook must never block or fail the session.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Stop hook payload arrives as JSON on stdin: {session_id, transcript_path, cwd, ...}.
payload="$(cat 2>/dev/null || true)"
cwd="$(printf '%s' "$payload" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print((d.get("cwd") or "") + "\n" + (d.get("transcript_path") or ""))' 2>/dev/null)"

# Guard: only coordinator worktree sessions birth arena decisions. Matches bug-coordinator
# today and any future *coordinator* (review-quorum / feature) with no edit here.
case "$cwd" in
  *worktrees*coordinator*) ;;
  *) exit 0 ;;
esac

setsid nohup python3 "$DIR/arena_refresh.py" --quiet >>"$DIR/refresh.log" 2>&1 &
exit 0
