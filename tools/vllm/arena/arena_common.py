"""Shared helpers for the model-arena projectors.

The arena is ONE JSONL log (`decisions.jsonl`) fed by several projectors, one
per source (bug-lane reconcile beads, eval review runs, eval diagnosis runs).
Every projector loads the existing log, merges in its own rows by decision_id
(preserving foreign rows and prior token counts), and rewrites. So running any
projector is always safe and idempotent, and transcript-derived token counts
survive even after the transcripts they came from are purged.
"""
import json
import os
import subprocess
from datetime import datetime

REPO = "/pvc/workspace"
ARENA_DIR = os.path.join(REPO, "tools", "vllm", "arena")
DECISIONS = os.path.join(ARENA_DIR, "decisions.jsonl")

ARENA_SCHEMA = "arena-decision.v0.2"


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
