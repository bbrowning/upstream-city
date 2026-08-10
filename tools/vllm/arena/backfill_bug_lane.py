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

RECONCILE_SCHEMA = "hard-bug-reconcile.v1"
DIAGNOSIS_SCHEMA = "hard-bug-diagnosis.v1"

# Bead-metadata keys gascity would stamp at dispatch (launch-time threading). Absent
# today -> the projector falls back to the agent x timestamp-window transcript scan.
# See README "Going-forward gaps" + the gascity follow-up proposal.
STAMP_SESSION = "gc.cc_session_id"   # Claude Code session UUID -> stable token join
STAMP_EFFORT = "gc.effort"           # resolved effort at dispatch
STAMP_MODEL = "gc.model_resolved"    # resolved model at dispatch


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


# ---- participants (identity + resolved model/effort + transcript tokens) -----
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
        stamp_sid = stamp_effort = stamp_model = None
        for b in beads:
            agent = agent or (meta(b, "gc.execution_routed_to") or "").split("/")[-1] or None
            provider = provider or meta(b, "gc.provider")
            model_intent = model_intent or meta(b, "opt_model") or None
            stamp_sid = stamp_sid or meta(b, STAMP_SESSION) or None
            stamp_effort = stamp_effort or meta(b, STAMP_EFFORT) or None
            stamp_model = stamp_model or meta(b, STAMP_MODEL) or None

        # STABLE join first: if gascity stamped the CC session id, read that session's
        # transcript directly (window-independent). Fall back to the timestamp window
        # if nothing was stamped, or the stamped file is gone (scan returns None).
        scan = None
        if agent:
            if stamp_sid:
                scan = A.scan_transcript_usage(agent, start, end, session_id=stamp_sid)
            if scan is None and start and end:
                scan = A.scan_transcript_usage(agent, start, end)

        cost = None
        cost_source = None
        if scan:
            cost = {"tokens": scan["tokens"], "messages": scan["messages"],
                    "join": scan["join"], "sessions": scan["sessions"]}
            # HOW tokens were obtained (harness-specific — see README "Token sourcing").
            # #session = stamped CC session id (stable); #window = agent x timestamp scan.
            cost_source = "claude-code/worktree-transcript#" + scan["join"]

        # model: stamped resolved > transcript-modal > opt_model intent
        model_resolved = stamp_model or (scan.get("model_resolved") if scan else None)
        # effort: `effort` is the INTENT proxy (pack config); `effort_resolved` is ground
        # truth (bead stamp when present, else the transcript's per-message effort).
        effort, effort_src = resolve_effort(role_agent(slot))
        if stamp_effort:
            effort_resolved, effort_resolved_src = stamp_effort, "bead-stamp"
        elif scan and scan.get("effort_resolved"):
            effort_resolved, effort_resolved_src = scan["effort_resolved"], "transcript"
        else:
            effort_resolved, effort_resolved_src = None, "unavailable"

        parts[slot] = {
            "slot": slot,
            "treatment": None,
            "lane_beads": sorted(b["id"] for b in beads),
            "agent": agent,
            "provider": provider,
            "model_intent": model_intent,       # opt_model (INTENT; often empty/invalid)
            "model_resolved": model_resolved,   # stamp or transcript (GROUND TRUTH)
            "model_canonical": A.canonical_model(model_resolved or model_intent),
            "effort": effort,                          # INTENT (pack config proxy)
            "effort_source": effort_src,
            "effort_resolved": effort_resolved,        # GROUND TRUTH (stamp/transcript)
            "effort_resolved_source": effort_resolved_src,
            "cc_session_id": stamp_sid or (scan["sessions"][0] if scan and len(scan.get("sessions") or []) == 1 else None),
            "window": {"start": start.isoformat() if start else None,
                       "end": end.isoformat() if end else None},
            "harness": "claude-code",   # model runtime; token sourcing below is harness-specific
            "cost": cost,
            "cost_source": cost_source,
            "scores": None,
            "verdict": None,
            "rank": None,
        }
    return parts


def project(export=None, out=A.DECISIONS, quiet=False):
    """Project bug-lane reconcile decisions into the arena log; return a stats dict.

    Idempotent + cost-preserving (via A.merge_write). Safe to re-run — this is the
    going-forward capture entry point (called by arena_refresh.py and by main())."""
    def say(*a):
        if not quiet:
            print(*a)

    export_path = export
    if not export_path:
        export_path = "/tmp/arena_vllm_beads.jsonl"
        say(f"exporting vllm beads -> {export_path}")
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
            recon = json.loads(raw)
        except (json.JSONDecodeError, TypeError):
            skipped += 1
            continue
        recon_by_key[(meta(b, "gc.root_bead_id"), recon.get("phase"), str(recon.get("round")))].append((b, recon))

    pack_commit = A.git_head()
    rows = []
    for key, members in sorted(recon_by_key.items()):
        root, phase, rnd = key
        members = sorted(members, key=lambda m: m[0]["id"])
        rep, recon = members[0]
        parts = build_participants(lanes_by_key.get(key, []))
        stronger = recon.get("stronger_lane")
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
            "subject_ref": recon.get("subject"),
            "subject_model": None,
            "lane": "bug",
            "phase": phase,
            "round": recon.get("round"),
            "at": rep.get("created_at"),
            "pack_commit": pack_commit,             # git HEAD at projection (≈ run-time if projected promptly)
            "blind": False,                         # coordinator sees lane labels + is opus-family
            "mode": "pairwise",
            "judge": {"kind": "coordinator", "agent": judge_agent, "provider": "claude",
                      "model": None, "effort": judge_effort},
            "criterion": "stronger diagnosis (mechanism rigor / test coverage / verification)",
            "aligned": recon.get("aligned"),
            "tie": tie,
            "participants": [parts[s] for s in sorted(parts)],
            "outcome": {"winner_slot": winner_slot,
                        "winner_model_canonical": winner["model_canonical"] if winner else None,
                        "ranking": None},
            "reason_tags": [],
            "rationale": recon.get("stronger_rationale"),
            "divergences": recon.get("divergences"),
            "next_action": recon.get("next_action"),
            "failure_class": recon.get("failure_class"),
            "failure_reason": recon.get("failure_reason"),
            "notes": None,
            "backfilled": True,
        })

    total, added, updated = A.merge_write(rows, out)
    say(f"\nbug-lane: {len(rows)} decisions projected ({skipped} unparseable skipped) "
        f"-> +{added} new / {updated} updated; log now {total} rows")
    if not quiet:
        _summary(rows)
    return {"source": "bug-lane", "rows": len(rows), "added": added,
            "updated": updated, "total": total, "skipped": skipped}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", help="pre-exported beads JSONL (else runs gc bd export)")
    ap.add_argument("--out", default=A.DECISIONS)
    args = ap.parse_args()
    project(export=args.export, out=args.out)


def _summary(rows):
    wins = defaultdict(int)
    aligned = ties = no_tok = 0
    subjects = defaultdict(int)
    efforts = defaultdict(int)
    joins = defaultdict(int)
    for r in rows:
        subjects[r["subject_ref"]] += 1
        aligned += bool(r["aligned"])
        ties += bool(r["tie"])
        wm = r["outcome"]["winner_model_canonical"]
        if wm:
            wins[wm] += 1
        for p in r["participants"]:
            c = p.get("cost")
            if not (c and c.get("messages")):
                no_tok += 1
            else:
                joins[c.get("join") or "?"] += 1
            efforts[p.get("effort_resolved") or p.get("effort")] += 1
    n = len(rows)
    parts = sum(len(r["participants"]) for r in rows)
    print("  winner by model: " + ", ".join(f"{m}={c}" for m, c in sorted(wins.items(), key=lambda x: -x[1])))
    print(f"  aligned=true {aligned}/{n}  ties {ties}  distinct subjects {len(subjects)}")
    print(f"  effort (resolved): " + ", ".join(f"{e}={c}" for e, c in efforts.items()))
    print(f"  participants with tokens: {parts - no_tok}/{parts}  "
          f"(join: " + ", ".join(f"{k}={v}" for k, v in joins.items()) + ")")


if __name__ == "__main__":
    main()
