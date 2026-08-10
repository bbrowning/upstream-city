#!/usr/bin/env python3
"""Project bug-lane judged comparisons (hard-bug reconcile beads) into the arena log.

Backfill AND going-forward capture: re-run this after each hard-bug run and it
merges new decisions into decisions.jsonl (preserving prior token counts even
after transcripts rotate). One row per unique judged comparison; the coordinator's
pick (`stronger_lane` + `stronger_rationale`) is the judgment; the two lane beads
supply each participant's model/provider; per-participant token counts come from
the per-worker Claude Code transcripts (deduped by message.id).

Tokens only, NO dollars (apply a rate table downstream). Effort is resolved from
the pack config (city.toml + agent.toml) — an INTENT proxy, accurate when this
runs promptly after the run; the durable fix is stamping effort into the bead at
dispatch (a gascity follow-up). See README.md.

Usage:  python3 backfill_bug_lane.py [--export path] [--out path]
"""
import argparse
import glob
import json
import os
import subprocess
import sys
from collections import defaultdict
from datetime import timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import arena_common as A

try:
    import tomllib
except ModuleNotFoundError:  # py<3.11
    tomllib = None

REPO = A.REPO
RIG_DIR = os.path.join(REPO, "rigs", "vllm")
DEVPACK_AGENTS = os.path.join(REPO, "dev-pack", "agents")
TRANSCRIPTS = os.path.expanduser("~/.claude/projects")
WORKTREE_PREFIX = "-pvc-workspace--gc-worktrees-vllm-"

RECONCILE_SCHEMA = "hard-bug-reconcile.v1"
DIAGNOSIS_SCHEMA = "hard-bug-diagnosis.v1"


def meta(b, k, default=None):
    return (b.get("metadata") or {}).get(k, default)


# ---- effort resolution from pack config (intent proxy) ----------------------
_CITY = None


def _city():
    global _CITY
    if _CITY is None and tomllib:
        try:
            with open(os.path.join(REPO, "city.toml"), "rb") as f:
                _CITY = tomllib.load(f)
        except Exception:
            _CITY = {}
    return _CITY or {}


def resolve_effort(agent):
    """agent e.g. 'bug-worker-a'. Precedence: city rig-patch > agent.toml > provider default."""
    if not tomllib or not agent:
        return None, "unavailable"
    city = _city()
    for rig in city.get("rigs", []):
        for patch in rig.get("patches", []):
            if patch.get("agent") == agent:
                e = (patch.get("option_defaults") or {}).get("effort")
                if e:
                    return e, "city-patch"
    at_path = os.path.join(DEVPACK_AGENTS, agent, "agent.toml")
    if os.path.exists(at_path):
        try:
            with open(at_path, "rb") as f:
                e = (tomllib.load(f).get("option_defaults") or {}).get("effort")
            if e:
                return e, "agent.toml"
        except Exception:
            pass
    e = (((city.get("providers") or {}).get("claude") or {}).get("option_defaults") or {}).get("effort")
    return e, ("provider-default" if e else "unavailable")


def role_agent(slot):
    """Map an arena slot ('worker-a') to the dev-pack config agent name."""
    if slot and slot.startswith("worker-"):
        return "bug-" + slot
    return slot


# ---- token counts from transcripts ------------------------------------------
def transcript_tokens(agent, start, end):
    d = os.path.join(TRANSCRIPTS, WORKTREE_PREFIX + agent)
    if not os.path.isdir(d):
        return None
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
                ts = A.parse_ts(rec.get("timestamp"))
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
    return {"tokens": tot, "messages": msgs, "model_resolved": resolved}


def build_participants(lane_beads):
    by_lane = defaultdict(list)
    for b in lane_beads:
        lane = meta(b, "gc.hard_bug_lane")
        if lane:
            by_lane[lane].append(b)

    parts = {}
    for lane, beads in by_lane.items():
        # lane labels appear as "hb-worker-a" AND "bug-worker-a"; judge uses "worker-a"
        slot = ("worker-" + lane.rsplit("worker-", 1)[-1]) if "worker-" in lane else lane
        starts = [A.parse_ts(b.get("created_at")) for b in beads]
        starts = [s for s in starts if s]
        ends = [A.parse_ts(b.get("closed_at")) for b in beads]
        ends = [e for e in ends if e]
        start = min(starts) if starts else None
        end = max(ends) if ends else (start + timedelta(hours=3) if start else None)

        agent = provider = model_intent = None
        for b in beads:
            agent = agent or (meta(b, "gc.execution_routed_to") or "").split("/")[-1] or None
            provider = provider or meta(b, "gc.provider")
            model_intent = model_intent or meta(b, "opt_model") or None

        cost = transcript_tokens(agent, start, end) if (agent and start and end) else None
        model_resolved = cost.get("model_resolved") if cost else None
        effort, effort_src = resolve_effort(role_agent(slot))
        parts[slot] = {
            "slot": slot,
            "treatment": None,
            "lane_beads": sorted(b["id"] for b in beads),
            "agent": agent,
            "provider": provider,
            "model_intent": model_intent,       # opt_model (INTENT; often empty/invalid)
            "model_resolved": model_resolved,   # from transcript (GROUND TRUTH)
            "model_canonical": A.canonical_model(model_resolved or model_intent),
            "effort": effort,
            "effort_source": effort_src,
            "window": {"start": start.isoformat() if start else None,
                       "end": end.isoformat() if end else None},
            "harness": "claude-code",   # model runtime; token sourcing below is harness-specific
            "cost": cost,
            # HOW tokens were obtained (harness-specific — see README "Token sourcing").
            # gascity agents run as full Claude Code sessions with their own transcripts.
            "cost_source": "claude-code/worktree-transcript" if cost else None,
            "scores": None,
            "verdict": None,
            "rank": None,
        }
    return parts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", help="pre-exported beads JSONL (else runs gc bd export)")
    ap.add_argument("--out", default=A.DECISIONS)
    args = ap.parse_args()

    export_path = args.export
    if not export_path:
        export_path = "/tmp/arena_vllm_beads.jsonl"
        print(f"exporting vllm beads -> {export_path}")
        subprocess.run(["gc", "bd", "export", "--all", "-o", export_path],
                       cwd=RIG_DIR, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(export_path) as f:
        beads = [json.loads(l) for l in f if l.strip()]

    lanes_by_key = defaultdict(list)
    for b in beads:
        if meta(b, "gc.output_json_schema") == DIAGNOSIS_SCHEMA:
            key = (meta(b, "gc.root_bead_id"), meta(b, "gc.hard_bug_phase"),
                   str(meta(b, "gc.hard_bug_round")))
            lanes_by_key[key].append(b)

    recon_by_key = defaultdict(list)
    skipped = 0
    for b in beads:
        if meta(b, "gc.output_json_schema") != RECONCILE_SCHEMA:
            continue
        raw = meta(b, "gc.output_json")
        if not raw:
            skipped += 1
            continue
        try:
            out = json.loads(raw)
        except (json.JSONDecodeError, TypeError):
            skipped += 1
            continue
        recon_by_key[(meta(b, "gc.root_bead_id"), out.get("phase"), str(out.get("round")))].append((b, out))

    pack_commit = A.git_head()
    rows = []
    for key, members in sorted(recon_by_key.items()):
        root, phase, rnd = key
        members = sorted(members, key=lambda m: m[0]["id"])
        rep, out = members[0]
        parts = build_participants(lanes_by_key.get(key, []))
        stronger = out.get("stronger_lane")
        tie = stronger == "tie"
        winner_slot = None if tie else stronger
        winner = parts.get(winner_slot) if winner_slot else None
        judge_agent = (meta(rep, "gc.run_target") or "").split("/")[-1] or None
        judge_effort, _ = resolve_effort("bug-coordinator")

        rows.append({
            "schema": A.ARENA_SCHEMA,
            "decision_id": f"{root}:{phase}:r{rnd}",
            "source": "bug-lane-reconcile",
            "source_refs": [m[0]["id"] for m in members],
            "root_bead": root,
            "subject_ref": out.get("subject"),
            "subject_model": None,
            "lane": "bug",
            "phase": phase,
            "round": out.get("round"),
            "at": rep.get("created_at"),
            "pack_commit": pack_commit,             # git HEAD at projection (≈ run-time if projected promptly)
            "blind": False,                         # coordinator sees lane labels + is opus-family
            "mode": "pairwise",
            "judge": {"kind": "coordinator", "agent": judge_agent, "provider": "claude",
                      "model": None, "effort": judge_effort},
            "criterion": "stronger diagnosis (mechanism rigor / test coverage / verification)",
            "aligned": out.get("aligned"),
            "tie": tie,
            "participants": [parts[s] for s in sorted(parts)],
            "outcome": {"winner_slot": winner_slot,
                        "winner_model_canonical": winner["model_canonical"] if winner else None,
                        "ranking": None},
            "reason_tags": [],
            "rationale": out.get("stronger_rationale"),
            "divergences": out.get("divergences"),
            "next_action": out.get("next_action"),
            "failure_class": out.get("failure_class"),
            "failure_reason": out.get("failure_reason"),
            "notes": None,
            "backfilled": True,
        })

    total, added, updated = A.merge_write(rows, args.out)
    print(f"\nbug-lane: {len(rows)} decisions projected ({skipped} unparseable skipped) "
          f"-> +{added} new / {updated} updated; log now {total} rows")
    _summary(rows)


def _summary(rows):
    wins = defaultdict(int)
    aligned = ties = no_tok = 0
    subjects = defaultdict(int)
    efforts = defaultdict(int)
    for r in rows:
        subjects[r["subject_ref"]] += 1
        aligned += bool(r["aligned"])
        ties += bool(r["tie"])
        wm = r["outcome"]["winner_model_canonical"]
        if wm:
            wins[wm] += 1
        for p in r["participants"]:
            if not (p.get("cost") and p["cost"].get("messages")):
                no_tok += 1
            efforts[p.get("effort")] += 1
    n = len(rows)
    parts = sum(len(r["participants"]) for r in rows)
    print("  winner by model: " + ", ".join(f"{m}={c}" for m, c in sorted(wins.items(), key=lambda x: -x[1])))
    print(f"  aligned=true {aligned}/{n}  ties {ties}  distinct subjects {len(subjects)}")
    print(f"  effort resolved: " + ", ".join(f"{e}={c}" for e, c in efforts.items()))
    print(f"  participants with tokens: {parts - no_tok}/{parts}")


if __name__ == "__main__":
    main()
