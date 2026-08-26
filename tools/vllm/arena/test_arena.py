#!/usr/bin/env python3
"""Hermetic tests for the arena runtime-state and token-attribution core.

Deterministic — synthesizes its own tiny transcripts in a temp dir (no dependency on
the ephemeral real worktree transcripts). Guards the bits most likely to regress:
  * dedup by message.id (streaming logs each message 2-4x),
  * the STABLE session-id join reads exactly one session (window-independent),
  * the FALLBACK window join scopes by [start,end] and can bleed sibling sessions,
  * a stamped-but-missing session file returns None (so the caller falls back).

Run: python3 tools/vllm/arena/test_arena.py
"""
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import arena_common as A


def _rec(sid, mid, ts, out, model="claude-opus-4-8", effort="high"):
    return {"sessionId": sid, "timestamp": ts, "effort": effort,
            "message": {"id": mid, "model": model,
                        "usage": {"input_tokens": 1, "output_tokens": out,
                                  "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}


def _write(dirpath, sid, records):
    with open(os.path.join(dirpath, sid + ".jsonl"), "w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


def _decision(decision_id, at=None, marker=None):
    row = {"decision_id": decision_id, "at": at}
    if marker:
        row["marker"] = marker
    return row


def _write_decisions(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")


def test_runtime_state_migration(root):
    """Legacy rows migrate once, late legacy ids remain readable, runtime wins conflicts."""
    old = (A.DECISIONS, A.LEGACY_DECISIONS, A.STATE_DIR, A.RUNTIME_DIR)
    try:
        A.RUNTIME_DIR = os.path.join(root, "city", ".gc", "runtime")
        A.STATE_DIR = os.path.join(A.RUNTIME_DIR, "arena")
        A.DECISIONS = os.path.join(A.STATE_DIR, "decisions.jsonl")
        A.LEGACY_DECISIONS = os.path.join(root, "city", "tools", "vllm", "arena",
                                          "decisions.jsonl")
        _write_decisions(A.LEGACY_DECISIONS, [
            _decision("old-a", "2026-01-01T00:00:00Z"),
            _decision("shared", marker="legacy"),
        ])

        rows = A.load_decisions()
        assert {r["decision_id"] for r in rows} == {"old-a", "shared"}, rows
        assert os.path.exists(A.DECISIONS)

        A.merge_write([_decision("shared", marker="runtime"), _decision("new-b")])
        _write_decisions(A.LEGACY_DECISIONS, [
            _decision("old-a"), _decision("shared", marker="stale"),
            _decision("late-c"),
        ])
        rows = A.load_decisions()
        by_id = {r["decision_id"]: r for r in rows}
        assert set(by_id) == {"old-a", "shared", "new-b", "late-c"}, rows
        assert by_id["shared"]["marker"] == "runtime", by_id["shared"]

        alternate = os.path.join(root, "alternate", "out.jsonl")
        _write_decisions(alternate, [_decision("explicit-only")])
        assert A.load_decisions(alternate) == [_decision("explicit-only")]
    finally:
        A.DECISIONS, A.LEGACY_DECISIONS, A.STATE_DIR, A.RUNTIME_DIR = old


def test_canonical_model():
    """Specific model id (family + version + codex variant); family derived in queries."""
    cases = {
        # anthropic — model ids, profile names, slugs, bare
        "claude-opus-4-8": "opus-4.8",
        "claude-opus-4-6 (xhigh)": "opus-4.6",
        "opus-4.8-xhigh": "opus-4.8",
        "vllm/pr-reviewer-opus48-xhigh": "opus-4.8",
        "pr-reviewer-opus46-xhigh": "opus-4.6",
        "claude-sonnet-5": "sonnet-5",
        "pr-reviewer-sonnet-xhigh": "sonnet",   # profile carries no version -> family only
        "sonnet": "sonnet",
        "claude-haiku-4-5": "haiku-4.5",
        "fable-5": "fable-5",
        # codex — sol vs luna vs terra kept DISTINCT (the whole point)
        "gpt-5.6-sol": "gpt-5.6-sol",
        "gpt-5.6-luna": "gpt-5.6-luna",
        "gpt-5.6-terra": "gpt-5.6-terra",
        "pr-reviewer-gpt56sol-medium": "gpt-5.6-sol",
        "gpt-5.5": "gpt-5.5",
        "gpt-5.3-codex": "gpt-5.3-codex",
        "o4-mini": "o4-mini",
        "o3": "o3",
        # unknown / empty
        "claude": "claude",
        None: None,
    }
    for raw, want in cases.items():
        got = A.canonical_model(raw)
        assert got == want, f"canonical_model({raw!r}) = {got!r}, want {want!r}"


def main():
    test_canonical_model()
    with tempfile.TemporaryDirectory() as root:
        test_runtime_state_migration(root)
        A.TRANSCRIPTS = root
        A.WORKTREE_PREFIX = "agent-"
        d = os.path.join(root, "agent-fake")
        os.makedirs(d)

        S1, S2 = "1111", "2222"
        dt = lambda h, m: datetime(2026, 8, 10, h, m, tzinfo=timezone.utc)  # window bounds
        t = lambda h, m: dt(h, m).isoformat()                              # record stamps
        # S1: msg m1 duplicated 3x (streaming) + m2 -> should dedup to 2 msgs, out=100+50=150
        _write(d, S1, [_rec(S1, "m1", t(19, 49), 100)] * 3 + [_rec(S1, "m2", t(19, 50), 50)])
        # S2: separate session, disjoint window, out=999
        _write(d, S2, [_rec(S2, "m3", t(18, 51), 999, model="claude-sonnet-5")])

        full = (dt(0, 0), dt(23, 0))     # window covering both sessions
        w1 = (dt(19, 0), dt(20, 0))      # window covering only S1

        # 1) stable session join: exactly S1, dedup applied, window-independent
        r = A.scan_transcript_usage("fake", session_id=S1)
        assert r["join"] == "session", r
        assert r["messages"] == 2, r
        assert r["tokens"]["output"] == 150, r
        assert r["sessions"] == [S1], r
        assert r["model_resolved"] == "claude-opus-4-8" and r["effort_resolved"] == "high", r

        # 2) stable session join still time-scopes within the file when a window is given
        r = A.scan_transcript_usage("fake", *w1, session_id=S1)
        assert r["messages"] == 2 and r["tokens"]["output"] == 150, r

        # 3) window fallback over the full window bleeds BOTH sessions (the fragility)
        r = A.scan_transcript_usage("fake", *full)
        assert r["join"] == "window", r
        assert r["messages"] == 3, r                       # m1(dedup) + m2 + m3
        assert r["tokens"]["output"] == 150 + 999, r
        assert set(r["sessions"]) == {S1, S2}, r

        # 4) window fallback scoped to S1's window excludes S2
        r = A.scan_transcript_usage("fake", *w1)
        assert r["messages"] == 2 and r["tokens"]["output"] == 150, r
        assert r["sessions"] == [S1], r

        # 5) stamped-but-missing session file -> None (caller then falls back to window)
        assert A.scan_transcript_usage("fake", *full, session_id="deadbeef") is None

        # 6) unknown agent -> None
        assert A.scan_transcript_usage("nope", *full) is None

    print("test_arena: all assertions passed")


if __name__ == "__main__":
    main()
