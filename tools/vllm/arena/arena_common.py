"""Shared helpers for the model-arena projectors.

The arena is ONE JSONL log (`decisions.jsonl`) fed by several projectors, one
per source (bug-lane reconcile beads, eval review runs, eval diagnosis runs).
Every projector loads the existing log, merges in its own rows by decision_id
(preserving foreign rows and prior token counts), and rewrites. So running any
projector is always safe and idempotent, and transcript-derived token counts
survive even after the transcripts they came from are purged.
"""
import glob
import json
import os
import subprocess
from collections import defaultdict
from datetime import datetime

REPO = "/pvc/workspace"
ARENA_DIR = os.path.join(REPO, "tools", "vllm", "arena")
DECISIONS = os.path.join(ARENA_DIR, "decisions.jsonl")

ARENA_SCHEMA = "arena-decision.v0.2"

# Where gascity agents' Claude Code transcripts live. Each gascity agent runs as its
# own Claude Code session in a per-agent worktree; the transcript dir is keyed by the
# worktree path, and each transcript file is named by its Claude Code session UUID.
TRANSCRIPTS = os.path.expanduser("~/.claude/projects")
WORKTREE_PREFIX = "-pvc-workspace--gc-worktrees-vllm-"


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def canonical_model(m):
    """Normalize any model string to a family: opus/sonnet/haiku/fable/mythos."""
    if not m:
        return None
    ml = str(m).lower()
    for fam in ("opus", "sonnet", "haiku", "fable", "mythos"):
        if fam in ml:
            return fam
    return ml


def git_head():
    try:
        return subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=REPO, capture_output=True, text=True, check=True,
        ).stdout.strip()
    except Exception:
        return None


def worktree_transcript_dir(agent):
    """Transcript dir for a gascity agent (e.g. 'bug-worker-a'), or None."""
    if not agent:
        return None
    return os.path.join(TRANSCRIPTS, WORKTREE_PREFIX + agent)


def _mode(counter):
    return max(counter, key=counter.get) if counter else None


def scan_transcript_usage(agent, start=None, end=None, session_id=None):
    """Sum Claude Code transcript usage for one gascity agent, deduped by message.id.

    Token attribution has two tiers (see README "Token sourcing"):

    * STABLE (preferred) — when `session_id` (a Claude Code session UUID stamped on
      the bead at dispatch, the launch-time-threading gascity follow-up) is given,
      read ONLY that session's transcript file. This is window-independent and immune
      to sibling sessions accumulating in the same reused worktree. The [start,end]
      window, if provided, still scopes *within* the file so a session reused across
      several beads is attributed per-bead. Returns None if the stamped file is absent
      (purged/renamed) so the caller can fall back.
    * FALLBACK — no `session_id`: scan every session file in the worktree and keep only
      records inside [start,end]. Fragile when a worktree holds overlapping sessions or
      the window is loose (e.g. a missing closed_at).

    Usage lines are logged 2-4x per message (streaming) — always dedup by message.id.
    Returns {tokens{input,output,cache_creation,cache_read,total}, messages,
    model_resolved, effort_resolved, join ("session"|"window"), sessions[]} or None
    if the worktree dir (or a stamped session file) is absent.
    """
    d = worktree_transcript_dir(agent)
    if not d or not os.path.isdir(d):
        return None
    if session_id:
        fp = os.path.join(d, session_id + ".jsonl")
        if not os.path.exists(fp):
            return None            # stamped but gone -> signal fallback to the caller
        files, join = [fp], "session"
    else:
        files, join = sorted(glob.glob(os.path.join(d, "*.jsonl"))), "window"

    tot = {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0}
    models = defaultdict(int)
    efforts = defaultdict(int)
    sessions = set()
    seen = set()
    msgs = 0
    windowed = start is not None and end is not None
    for fp in files:
        with open(fp) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                m = rec.get("message") or {}
                u = m.get("usage")
                if not u:
                    continue
                if windowed:
                    ts = parse_ts(rec.get("timestamp"))
                    if ts is None or ts < start or ts > end:
                        continue
                mid = m.get("id")
                if mid and mid in seen:
                    continue
                if mid:
                    seen.add(mid)
                msgs += 1
                tot["input"] += u.get("input_tokens", 0) or 0
                tot["output"] += u.get("output_tokens", 0) or 0
                tot["cache_creation"] += u.get("cache_creation_input_tokens", 0) or 0
                tot["cache_read"] += u.get("cache_read_input_tokens", 0) or 0
                if m.get("model"):
                    models[m["model"]] += 1
                if rec.get("effort"):
                    efforts[rec["effort"]] += 1
                if rec.get("sessionId"):
                    sessions.add(rec["sessionId"])
    tot["total"] = sum(tot[k] for k in ("input", "output", "cache_creation", "cache_read"))
    return {
        "tokens": tot,
        "messages": msgs,
        "model_resolved": _mode(models),
        "effort_resolved": _mode(efforts),
        "join": join,
        "sessions": sorted(sessions),
    }


def load_decisions(path=DECISIONS):
    if not os.path.exists(path):
        return []
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def _preserve_cost(new, old):
    """Carry token counts (and resolved model) from an existing row into a fresh
    projection when the fresh one couldn't recover them (e.g. transcript purged)."""
    old_parts = {p.get("slot"): p for p in old.get("participants", [])}
    for p in new.get("participants", []):
        c = p.get("cost")
        has_new = bool(c and c.get("messages"))
        op = old_parts.get(p.get("slot"))
        if not has_new and op:
            oc = op.get("cost")
            if oc and oc.get("messages"):
                p["cost"] = oc
                p["cost_source"] = op.get("cost_source", p.get("cost_source"))
                if not p.get("model_resolved"):
                    p["model_resolved"] = op.get("model_resolved")
                    p["model_canonical"] = p.get("model_canonical") or op.get("model_canonical")
                if not p.get("effort_resolved"):
                    p["effort_resolved"] = op.get("effort_resolved")
                    p["effort_resolved_source"] = op.get("effort_resolved_source")
    return new


def merge_write(new_rows, path=DECISIONS):
    """Merge new_rows into the log by decision_id (new wins, cost preserved),
    keep foreign rows untouched, write sorted by timestamp. Returns (total, added, updated)."""
    existing = load_decisions(path)
    by_id = {r["decision_id"]: r for r in existing}
    added = updated = 0
    for r in new_rows:
        did = r["decision_id"]
        if did in by_id:
            _preserve_cost(r, by_id[did])
            updated += 1
        else:
            added += 1
        by_id[did] = r
    rows = sorted(by_id.values(), key=lambda r: (r.get("at") or "", r.get("decision_id")))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    return len(rows), added, updated
