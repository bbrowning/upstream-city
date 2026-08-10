#!/usr/bin/env python3
"""Hermetic tests for the arena token-attribution core (arena_common.scan_transcript_usage).

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


def main():
    with tempfile.TemporaryDirectory() as root:
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
