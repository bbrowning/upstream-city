#!/usr/bin/env python3
"""Backfill the model-arena decision log from existing hard-bug reconcile beads.

One JSONL row per *unique judged comparison* on the bug lane (dev-pack
`hard-bug-round.reconcile`). The coordinator's pick (`stronger_lane` +
`stronger_rationale`) is the judgment; the two lane beads supply each
participant's model/provider; per-participant token counts are recovered from
the per-worker Claude Code transcripts.

Design notes (see README.md):
  - We log DECISIONS (events). Ratings/leaderboards are queries over this log.
  - Tokens only, NO dollars. `.gc/usage.jsonl` is empty (metering disabled +
    Vertex), so cost lives in the Claude Code transcripts as token counts;
    Vertex $ isn't in them. Apply a rate table downstream whenever you want.
  - Reconcile + lane beads come in work+control PAIRS -> dedup by
    (root, phase, round) / (root, phase, round, lane).
  - Transcript usage lines are logged multiple times per message -> dedup by
    message.id before summing.

Usage:  python3 backfill_bug_lane.py [--export path] [--out path]
"""
import argparse
import glob
import json
import os
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timedelta

REPO = "/pvc/workspace"
RIG_DIR = os.path.join(REPO, "rigs", "vllm")
ARENA_DIR = os.path.join(REPO, "tools", "vllm", "arena")
TRANSCRIPTS = os.path.expanduser("~/.claude/projects")
WORKTREE_PREFIX = "-pvc-workspace--gc-worktrees-vllm-"

RECONCILE_SCHEMA = "hard-bug-reconcile.v1"
DIAGNOSIS_SCHEMA = "hard-bug-diagnosis.v1"

# arena record schema version — bump on breaking field changes
ARENA_SCHEMA = "arena-decision.v0.1"


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def canonical_model(m):
    if not m:
        return None
    ml = m.lower()
    for fam in ("opus", "sonnet", "haiku", "fable", "mythos"):
        if fam in ml:
            return fam
    return ml


def meta(b, k, default=None):
    return (b.get("metadata") or {}).get(k, default)


def export_beads(path):
    subprocess.run(
        ["gc", "bd", "export", "--all", "-o", path],
        cwd=RIG_DIR, check=True,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def load_jsonl(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def transcript_tokens(agent, start, end):
    """Sum message.id-deduped usage for one agent's transcripts in [start, end]."""
    d = os.path.join(TRANSCRIPTS, WORKTREE_PREFIX + agent)
    if not os.path.isdir(d):
        return {"transcript_dir_found": False, "messages": 0, "model_resolved": None,
                "tokens": None}
    tot = {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0}
    models = defaultdict(int)
    seen = set()
    msgs = 0
    for fp in glob.glob(os.path.join(d, "*.jsonl")):
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
    tot["total"] = sum(tot[k] for k in ("input", "output", "cache_creation", "cache_read"))
    resolved = max(models, key=models.get) if models else None
    return {"transcript_dir_found": True, "messages": msgs,
            "model_resolved": resolved, "tokens": tot}


def build_participants(lane_beads):
    """lane_beads: list of diagnosis beads sharing (root, phase, round).
    Returns {slot: participant-dict}, deduping work/control pairs per lane and
    unioning their time windows."""
    by_lane = defaultdict(list)
    for b in lane_beads:
        lane = meta(b, "gc.hard_bug_lane")  # e.g. "hb-worker-a"
        if lane:
            by_lane[lane].append(b)

    parts = {}
    for lane, beads in by_lane.items():
        # lane labels appear as both "hb-worker-a" (hard-bug rig) and
        # "bug-worker-a" (dev-pack); the judge's stronger_lane is "worker-a".
        slot = ("worker-" + lane.rsplit("worker-", 1)[-1]) if "worker-" in lane else lane
        starts = [parse_ts(b.get("created_at")) for b in beads]
        starts = [s for s in starts if s]
        ends = [parse_ts(b.get("closed_at")) for b in beads]
        ends = [e for e in ends if e]
        start = min(starts) if starts else None
        # fall back to a generous window if a bead never closed
        end = max(ends) if ends else (start + timedelta(hours=3) if start else None)

        agent = None
        provider = None
        model_intent = None
        for b in beads:
            agent = agent or (meta(b, "gc.execution_routed_to") or "").split("/")[-1] or None
            provider = provider or meta(b, "gc.provider")
            model_intent = model_intent or meta(b, "opt_model") or None

        cost = None
        if agent and start and end:
            cost = transcript_tokens(agent, start, end)

        model_resolved = cost.get("model_resolved") if cost else None
        parts[slot] = {
            "slot": slot,
            "lane": lane,
            "lane_beads": sorted(b["id"] for b in beads),
            "agent": agent,
            "provider": provider,
            "model_intent": model_intent,          # opt_model on the bead (INTENT, may be wrong)
            "model_resolved": model_resolved,       # from transcript (GROUND TRUTH)
            "model_canonical": canonical_model(model_resolved or model_intent),
            "effort": None,                         # not recorded anywhere historically
            "window": {"start": start.isoformat() if start else None,
                       "end": end.isoformat() if end else None},
            "cost": cost,                           # {tokens:{input,output,cache_*,total}, messages, ...}
        }
    return parts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", help="pre-exported beads JSONL (else runs gc bd export)")
    ap.add_argument("--out", default=os.path.join(ARENA_DIR, "decisions.jsonl"))
    args = ap.parse_args()

    export_path = args.export
    if not export_path:
        export_path = "/tmp/arena_vllm_beads.jsonl"
        print(f"exporting vllm beads -> {export_path}")
        export_beads(export_path)
    beads = load_jsonl(export_path)

    # index diagnosis (lane) beads by (root, phase, round)
    lanes_by_key = defaultdict(list)
    for b in beads:
        if meta(b, "gc.output_json_schema") == DIAGNOSIS_SCHEMA:
            key = (meta(b, "gc.root_bead_id"),
                   meta(b, "gc.hard_bug_phase"),
                   str(meta(b, "gc.hard_bug_round")))
            lanes_by_key[key].append(b)

    # group reconcile beads by (root, phase, round), keep parseable ones
    recon_by_key = defaultdict(list)
    skipped_unparseable = 0
    for b in beads:
        if meta(b, "gc.output_json_schema") != RECONCILE_SCHEMA:
            continue
        raw = meta(b, "gc.output_json")
        if not raw:
            skipped_unparseable += 1
            continue
        try:
            out = json.loads(raw)
        except (json.JSONDecodeError, TypeError):
            skipped_unparseable += 1
            continue
        root = meta(b, "gc.root_bead_id")
        key = (root, out.get("phase"), str(out.get("round")))
        recon_by_key[key].append((b, out))

    rows = []
    for key, members in sorted(recon_by_key.items()):
        root, phase, rnd = key
        # representative: deterministic pick; keep all bead ids as provenance
        members_sorted = sorted(members, key=lambda m: m[0]["id"])
        rep_bead, out = members_sorted[0]
        source_beads = [m[0]["id"] for m in members_sorted]

        parts = build_participants(lanes_by_key.get(key, []))

        stronger = out.get("stronger_lane")            # worker-a | worker-b | tie
        tie = (stronger == "tie")
        winner_slot = None if tie else stronger
        winner = parts.get(winner_slot) if winner_slot else None

        rows.append({
            "schema": ARENA_SCHEMA,
            "decision_id": f"{root}:{phase}:r{rnd}",
            "source": "bug-lane-reconcile",
            "source_beads": source_beads,
            "root_bead": root,
            "subject_ref": out.get("subject"),
            "lane": "bug",
            "phase": phase,
            "round": out.get("round"),
            "at": rep_bead.get("created_at"),
            "pack_version": None,                       # not recorded historically
            "blind": False,                             # coordinator sees lane labels
            "judge": {
                "agent": (meta(rep_bead, "gc.run_target") or "").split("/")[-1] or None,
                "provider": "claude",
                "model": None,                          # judge model not stamped per-run
                "effort": None,
            },
            "criterion": "stronger diagnosis (mechanism rigor / test coverage / verification)",
            "aligned": out.get("aligned"),
            "tie": tie,
            "participants": [parts[s] for s in sorted(parts)],
            "outcome": {
                "winner_slot": winner_slot,
                "winner_model_canonical": winner["model_canonical"] if winner else None,
            },
            "reason_tags": [],                          # controlled vocab: going-forward field
            "rationale": out.get("stronger_rationale"),
            "divergences": out.get("divergences"),      # keeps the loser's positions
            "next_action": out.get("next_action"),
            "failure_class": out.get("failure_class"),
            "failure_reason": out.get("failure_reason"),
            "backfilled": True,
        })

    os.makedirs(ARENA_DIR, exist_ok=True)
    with open(args.out, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")

    _summary(rows, skipped_unparseable, args.out)


def _summary(rows, skipped, out_path):
    print(f"\nwrote {len(rows)} decisions -> {out_path}"
          f"  ({skipped} unparseable reconcile beads skipped)\n")
    wins = defaultdict(int)
    aligned = 0
    ties = 0
    subjects = defaultdict(int)
    no_tokens = 0
    for r in rows:
        subjects[r["subject_ref"]] += 1
        if r["aligned"]:
            aligned += 1
        if r["tie"]:
            ties += 1
        wm = r["outcome"]["winner_model_canonical"]
        if wm:
            wins[wm] += 1
        for p in r["participants"]:
            c = p.get("cost")
            if not c or not c.get("tokens") or not c.get("messages"):
                no_tokens += 1
    print("winner by canonical model:")
    for m, n in sorted(wins.items(), key=lambda x: -x[1]):
        print(f"    {m:8} {n}")
    print(f"\naligned=true: {aligned}/{len(rows)}   ties: {ties}")
    print(f"distinct subjects: {len(subjects)}  (repeats mean fewer independent tasks)")
    for s, n in sorted(subjects.items(), key=lambda x: -x[1]):
        print(f"    {s}: {n}")
    parts_total = sum(len(r["participants"]) for r in rows)
    print(f"\nparticipants with token data: {parts_total - no_tokens}/{parts_total}")
    print("\nCAVEATS: non-blind coordinator judge (opus family); token attribution is")
    print("a per-agent timestamp-window join (assumes a worker wasn't running two")
    print("decisions concurrently); effort unrecorded historically; dollars deferred.")


if __name__ == "__main__":
    main()
