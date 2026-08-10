#!/usr/bin/env python3
"""Idempotent arena capture — run every projector once, merge into decisions.jsonl.

This is the SINGLE entry point every auto-capture trigger calls (the Stop hook, a
manual run, or `--loop`). It runs all source projectors; each is idempotent and
cost-preserving (merges by decision_id, preserves prior transcript-derived token
counts), so running this any number of times is always safe. New N>=2 decisions land
automatically; transcript token counts are captured before those worktree transcripts
rotate (Claude Code cleanupPeriodDays, ~30d default).

Concurrency: an flock on .refresh.lock makes overlapping runs a no-op (the Stop hook
can fire while a prior refresh is mid-flight). A held lock -> clean exit 0.

Usage:
  python3 arena_refresh.py                 # one pass (default; used by the Stop hook)
  python3 arena_refresh.py --quiet         # one pass, only the log line to stdout
  python3 arena_refresh.py --loop 6h       # periodic fallback (no cron/systemd here)
  python3 arena_refresh.py --out /tmp/x.jsonl   # project to an alternate log (tests)
"""
import argparse
import fcntl
import os
import sys
import time
import traceback
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import arena_common as A
import backfill_bug_lane
import eval_to_arena

LOCK = os.path.join(A.ARENA_DIR, ".refresh.lock")
LOG = os.path.join(A.ARENA_DIR, "refresh.log")

# Source projectors run on every refresh. Each takes (out, quiet) and returns a stats
# dict {source, rows, added, updated, total}. Add review-quorum / feature here as they
# gain N>=2 comparisons — the trigger, lock, and log all come for free.
PROJECTORS = [
    ("bug-lane", lambda out, quiet: backfill_bug_lane.project(out=out, quiet=quiet)),
    ("eval", lambda out, quiet: eval_to_arena.project(out=out, quiet=quiet)),
]


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _logline(msg):
    try:
        with open(LOG, "a") as f:
            f.write(msg + "\n")
    except Exception:
        pass


def refresh_once(out=A.DECISIONS, quiet=False):
    """Run every projector once under the lock. Returns True on a full clean pass."""
    lock_fd = os.open(LOCK, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if not quiet:
                print("arena_refresh: another refresh holds the lock; skipping")
            _logline(f"{_now()}\tskip\tlock-held")
            return False

        results, ok = [], True
        for name, fn in PROJECTORS:
            try:
                results.append(fn(out, quiet))
            except Exception as e:  # one projector failing must not sink the others
                ok = False
                if not quiet:
                    traceback.print_exc()
                _logline(f"{_now()}\terror\t{name}\t{type(e).__name__}: {e}")

        head = A.git_head()
        parts = [f"{r['source']}:+{r['added']}/~{r['updated']}={r['total']}" for r in results]
        _logline(f"{_now()}\t{'ok' if ok else 'partial'}\tpack={head}\t" + " ".join(parts))
        if quiet:  # the Stop hook wants exactly one line on stdout
            print(f"arena_refresh {_now()} " + " ".join(parts))
        return ok
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)


def _parse_duration(s):
    s = str(s).strip().lower()
    mult = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    if s and s[-1] in mult:
        return int(float(s[:-1]) * mult[s[-1]])
    return int(float(s))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=A.DECISIONS)
    ap.add_argument("--quiet", action="store_true", help="only emit the summary line (hook mode)")
    ap.add_argument("--loop", metavar="EVERY",
                    help="run forever, sleeping EVERY between passes (e.g. 6h, 30m, 900). "
                         "Fallback daemon mode — this container has no cron/systemd-user.")
    args = ap.parse_args()

    if not args.loop:
        ok = refresh_once(out=args.out, quiet=args.quiet)
        sys.exit(0 if ok else 1)

    every = _parse_duration(args.loop)
    print(f"arena_refresh: looping every {every}s (Ctrl-C to stop)")
    while True:
        try:
            refresh_once(out=args.out, quiet=args.quiet)
        except Exception:
            traceback.print_exc()
        time.sleep(every)


if __name__ == "__main__":
    main()
