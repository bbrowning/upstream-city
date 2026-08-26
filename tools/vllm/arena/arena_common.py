"""Shared helpers for the model-arena projectors.

The arena is ONE runtime JSONL log (`decisions.jsonl`) fed by several projectors, one
per source (bug-lane reconcile beads, eval review runs, eval diagnosis runs).
Every projector loads the existing log, merges in its own rows by decision_id
(preserving foreign rows and prior token counts), and rewrites. So running any
projector is always safe and idempotent, and transcript-derived token counts
survive even after the transcripts they came from are purged.
"""
import glob
import json
import os
import re
import subprocess
import tempfile
from collections import defaultdict
from datetime import datetime

REPO = os.path.abspath(os.environ.get("GC_CITY_PATH") or
                       os.environ.get("GC_CITY") or "/pvc/workspace")
ARENA_DIR = os.path.join(REPO, "tools", "vllm", "arena")
LEGACY_DECISIONS = os.path.join(ARENA_DIR, "decisions.jsonl")
RUNTIME_DIR = os.path.abspath(os.environ.get("GC_CITY_RUNTIME_DIR") or
                              os.path.join(REPO, ".gc", "runtime"))
STATE_DIR = os.path.abspath(os.environ.get("GC_ARENA_STATE_DIR") or
                            os.path.join(RUNTIME_DIR, "arena"))
DECISIONS = os.path.abspath(os.environ.get("GC_ARENA_DECISIONS") or
                            os.path.join(STATE_DIR, "decisions.jsonl"))

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


def _model_version(rest):
    """Version right after a family token -> dotted str ('4-8'/'4.8'/'48' -> '4.8',
    '5' -> '5'), or None. Reads the messy tail of a model id / profile name / slug."""
    r = rest.lstrip("-. ")
    m = re.match(r"(\d)[.-](\d)", r)      # 4-8, 4.8
    if m:
        return f"{m.group(1)}.{m.group(2)}"
    m = re.match(r"(\d)(\d)(?!\d)", r)    # 48 -> 4.8 (profile-name form)
    if m:
        return f"{m.group(1)}.{m.group(2)}"
    m = re.match(r"(\d+)", r)             # 5
    if m:
        return m.group(1)
    return None


def canonical_model(m):
    """Normalize any model/profile string to a SPECIFIC model id — family + version
    (+ codex variant): opus-4.8, opus-4.6, sonnet-5, haiku-4.5, fable-5, gpt-5.6-sol,
    gpt-5.6-luna, gpt-5.3-codex, o4-mini. The vendor FAMILY (opus/sonnet/gpt/o…) is
    derivable at query time from the leading token, so keep the specific id here and
    roll up in queries. A bare family with no version stays the family ('sonnet'); an
    unrecognized string is returned lowercased as-is.

    Inputs are deliberately messy — model ids ('claude-opus-4-8'), profile names
    ('pr-reviewer-opus48-xhigh', 'pr-reviewer-gpt56sol-medium'), slugs
    ('opus-4.6-xhigh'), bare families ('sonnet') — so match the family token and read
    the version from whatever follows it."""
    if not m:
        return None
    s = str(m).lower()
    for fam in ("opus", "sonnet", "haiku", "fable", "mythos"):   # Anthropic families
        i = s.find(fam)
        if i != -1:
            ver = _model_version(s[i + len(fam):])
            return f"{fam}-{ver}" if ver else fam
    g = re.search(r"gpt[- ]?(\d)\.?(\d)?", s)                    # codex: gpt-5.6-sol / gpt56sol
    if g:
        ver = g.group(1) + (f".{g.group(2)}" if g.group(2) else "")
        variant = re.search(r"(sol|terra|luna|codex)", s)
        return f"gpt-{ver}" + (f"-{variant.group(1)}" if variant else "")
    o = re.search(r"\b(o[34](?:-mini)?)\b", s)                   # openai reasoning: o3 / o4-mini
    if o:
        return o.group(1)
    return s


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

    * STABLE (preferred) — when `session_id` (a Claude Code session UUID the worker
      self-stamped onto the bead at emit time via emit-json.sh, from
      $CLAUDE_CODE_SESSION_ID; pack-only, no gascity change) is given, read ONLY that
      session's transcript file. This is window-independent and immune to sibling
      sessions accumulating in the same reused worktree. The [start,end]
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


def _read_decisions(path):
    if not os.path.exists(path):
        return []
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def _write_decisions(path, rows):
    """Atomically replace a log and fsync both its contents and directory entry."""
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".decisions.", suffix=".tmp", dir=directory,
                               text=True)
    try:
        with os.fdopen(fd, "w") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        dir_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def migrate_legacy_decisions(path=None):
    """Import the retired repository log into the default runtime log.

    This remains intentionally idempotent for a compatibility window: an old checkout
    may append a new decision to the legacy path after the runtime log was created.
    Missing legacy ids are imported, while an existing runtime row wins on collision.
    Explicit alternate output paths never invoke this migration.
    """
    path = path or DECISIONS
    if os.path.abspath(path) != os.path.abspath(DECISIONS):
        return False
    legacy = _read_decisions(LEGACY_DECISIONS)
    current = _read_decisions(path)
    if not legacy:
        return False
    by_id = {r["decision_id"]: r for r in legacy}
    by_id.update({r["decision_id"]: r for r in current})
    rows = sorted(by_id.values(), key=lambda r: (r.get("at") or "", r.get("decision_id")))
    if rows == current:
        return False
    _write_decisions(path, rows)
    return True


def load_decisions(path=None):
    path = path or DECISIONS
    migrate_legacy_decisions(path)
    return _read_decisions(path)


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


def merge_write(new_rows, path=None):
    """Merge new_rows into the log by decision_id (new wins, cost preserved),
    keep foreign rows untouched, write sorted by timestamp. Returns (total, added, updated)."""
    path = path or DECISIONS
    existing = load_decisions(path)
    by_id = {r["decision_id"]: r for r in existing}
    added = updated = 0
    for r in new_rows:
        did = r["decision_id"]
        if did in by_id:
            old = by_id[did]
            _preserve_cost(r, old)
            # pack_commit records the pack version at the decision's FIRST capture
            # (~run-time when projected promptly). Pin it across re-projections so an
            # idempotent re-run (e.g. the arena-capture order every 30m) doesn't churn
            # existing rows' pack_commit to whatever HEAD happens to be now.
            if old.get("pack_commit"):
                r["pack_commit"] = old["pack_commit"]
            updated += 1
        else:
            added += 1
        by_id[did] = r
    rows = sorted(by_id.values(), key=lambda r: (r.get("at") or "", r.get("decision_id")))
    _write_decisions(path, rows)
    return len(rows), added, updated
