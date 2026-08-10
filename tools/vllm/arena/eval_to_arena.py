#!/usr/bin/env python3
"""Project the offline eval harness (tools/vllm/eval/) into the arena log.

The eval judge is BLIND (arms anonymized), which makes it the calibration anchor
against the (non-blind) production bug-lane coordinator. Two families:

  - REVIEW  (run-2026-08-08*): pairwise, `more_useful_to_maintainer`. Arms are the
    SAME model (opus) differing only by treatment (A=current-pack / B=lean-persona)
    — so these are persona/config bake-offs, not model comparisons.
  - DIAGNOSIS (run-2026-08-10): N-way (4 arms), per-arm grades + verdict, no winner
    field. Arms differ by model AND treatment (baseline/treat/bonly x opus/sonnet).
    We derive an ordinal rank from `verdict` (auditable; raw grades kept in scores).

COST: eval arms are Agent-tool subagents, NOT gascity sessions — their token usage
is never persisted (only the parent's tool_result output). So cost is null and
cost_source records why. This is harness-specific; see README "Token sourcing".

Usage:  python3 eval_to_arena.py [--out path]
"""
import argparse
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import arena_common as A

EVAL = os.path.join(A.REPO, "tools", "vllm", "eval")
CASES = os.path.join(EVAL, "cases")

REVIEW_RUNS = ["run-2026-08-08", "run-2026-08-08b", "run-2026-08-08c", "run-2026-08-08d"]
DIAGNOSIS_RUNS = {"run-2026-08-10": "caseVPD"}   # judged only; run-2026-08-10b has no judge -> skipped
REVIEW_TREATMENT = {"A": "current-pack", "B": "lean-persona"}   # RUNBOOK convention (not in arm files)
VERDICT_RANK = {"strong-catch": 3, "catch": 2, "partial": 1, "miss": 0}
COST_NA = "claude-code/agent-tool-subagent(usage-not-persisted)"


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def case_meta(case):
    return load_json(os.path.join(CASES, case, "meta.json")) or {}


def parse_blindmap(path):
    """Two formats:
       review:    'caseX: review1=B review2=A'  -> {case: {review1:'B', ...}}
       diagnosis: 'review1=treat-sonnet'        -> {'_': {review1:'treat-sonnet', ...}}"""
    out = {}
    if not os.path.exists(path):
        return out
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or "=" not in line:
                continue
            if ":" in line.split("=")[0]:
                case, rest = line.split(":", 1)
                d = out.setdefault(case.strip(), {})
                for tok in rest.split():
                    if "=" in tok:
                        k, v = tok.split("=", 1)
                        d[k.strip()] = v.strip()
            else:
                d = out.setdefault("_", {})
                k, v = line.split("=", 1)
                d[k.strip()] = v.strip()
    return out


def eval_participant(slot, treatment, model_canonical, provider, scores=None, verdict=None,
                     model_intent=None):
    return {
        "slot": slot,
        "treatment": treatment,
        "provider": provider,
        "model_intent": model_intent,
        "model_resolved": None,          # eval arm outputs don't carry a verified resolved model
        "model_canonical": model_canonical,
        "effort": None,
        "effort_source": "unrecorded",
        "harness": "claude-code",        # arms ran as Agent-tool subagents
        "cost": None,                    # subagent usage not persisted (see module docstring)
        "cost_source": COST_NA,
        "scores": scores,
        "verdict": verdict,
        "rank": None,
    }


def project_review(run, pack_commit):
    d = os.path.join(EVAL, run)
    bm = parse_blindmap(os.path.join(d, "blind-map.txt"))
    rows = []
    for jf in sorted(glob.glob(os.path.join(d, "judge-case*.json"))):
        j = load_json(jf)
        if not j:
            continue
        case = j.get("case") or os.path.basename(jf)[len("judge-"):-len(".json")]
        cmap = bm.get(case, {})
        if not cmap:
            continue
        meta = case_meta(case)
        parts = []
        for rk in ("review1", "review2"):
            arm = cmap.get(rk)
            if not arm:
                continue
            scores = {
                "gold_catch": (j.get("gold_catch") or {}).get(rk),
                "signal": (j.get("signal") or {}).get(rk),
                "noise": (j.get("noise") or {}).get(rk),
                "groundedness": (j.get("groundedness") or {}).get(rk),
                "false_positives": (j.get("false_positives") or {}).get(rk),
                "_review_key": rk,
            }
            parts.append(eval_participant(
                slot=arm, treatment=REVIEW_TREATMENT.get(arm, arm),
                model_canonical="opus",           # RESULTS: both arms opus (config-only bake-off)
                provider="claude", scores=scores, model_intent="opus"))
        winner_rk = j.get("more_useful_to_maintainer")
        tie = winner_rk == "tie"
        winner_slot = cmap.get(winner_rk) if winner_rk in ("review1", "review2") else None
        rows.append({
            "schema": A.ARENA_SCHEMA,
            "decision_id": f"eval:{run}:{case}",
            "source": "eval-review",
            "source_refs": [os.path.relpath(jf, A.REPO)],
            "root_bead": None,
            "subject_ref": case,
            "subject_model": None,                # review subject is a PR diff, not a model
            "subject_source": meta.get("source"),  # e.g. "vllm#51391"
            "lane": "review",
            "phase": None, "round": None,
            "at": None,                           # eval judge output carries no timestamp
            "pack_commit": pack_commit,
            "blind": True,
            "mode": "pairwise",
            "judge": {"kind": "eval-blind", "agent": "general-purpose", "provider": "claude",
                      "model": None, "effort": None},
            "criterion": "more useful to the maintainer (blind)",
            "aligned": None,
            "tie": tie,
            "participants": parts,
            "outcome": {"winner_slot": winner_slot,
                        "winner_model_canonical": "opus" if winner_slot else None,
                        "ranking": None},
            "reason_tags": [],
            "rationale": j.get("rationale"),
            "divergences": None,
            "next_action": None,
            "failure_class": None, "failure_reason": None,
            "notes": "Review arms are the SAME model (opus); the compared axis is persona/config (treatment).",
            "backfilled": True,
        })
    return rows


def project_diagnosis(run, case, pack_commit):
    d = os.path.join(EVAL, run)
    j = load_json(os.path.join(d, "judge.json"))
    if not j or "reviews" not in j:
        return []
    bm = parse_blindmap(os.path.join(d, "blind-map.txt")).get("_", {})
    meta = case_meta(case)
    parts = []
    for rv in j["reviews"]:
        rk = rv.get("id")
        arm = bm.get(rk, rk)                       # e.g. "treat-sonnet"
        armfile = load_json(os.path.join(d, f"{arm}.json")) or {}
        treatment = arm.rsplit("-", 1)[0] if "-" in arm else arm  # baseline/treat/bonly
        scores = {k: rv.get(k) for k in ("gold1", "gold1_why", "gold2", "gold3", "noise")}
        p = eval_participant(
            slot=arm, treatment=treatment,
            model_canonical=A.canonical_model(armfile.get("model")),
            provider=armfile.get("provider"), scores=scores, verdict=rv.get("verdict"),
            model_intent=armfile.get("model"))
        p["_rankval"] = VERDICT_RANK.get(rv.get("verdict"), -1)
        parts.append(p)
    # derived ordinal ranking from verdict (auditable; raw grades kept in scores)
    order = sorted(parts, key=lambda p: -p["_rankval"])
    for i, p in enumerate(order):
        p["rank"] = i + 1
    ranking = [p["slot"] for p in order]
    top = order[0]["_rankval"] if order else None
    winner_slot = order[0]["slot"] if order and (len(order) == 1 or order[1]["_rankval"] < top) else None
    for p in parts:
        p.pop("_rankval", None)
    return [{
        "schema": A.ARENA_SCHEMA,
        "decision_id": f"eval:{run}:{case}",
        "source": "eval-diagnosis",
        "source_refs": [os.path.relpath(os.path.join(d, "judge.json"), A.REPO)],
        "root_bead": None,
        "subject_ref": case,
        "subject_model": meta.get("model"),        # e.g. "inkling-small"
        "subject_source": (meta.get("source") or {}),
        "lane": "diagnosis",
        "phase": None, "round": None,
        "at": None,
        "pack_commit": pack_commit,
        "blind": True,
        "mode": "nway",
        "judge": {"kind": "eval-blind", "agent": "general-purpose", "provider": "claude",
                  "model": None, "effort": None},
        "criterion": "diagnosis quality vs answer key (blind)",
        "aligned": None,
        "tie": winner_slot is None,
        "participants": parts,
        "outcome": {"winner_slot": winner_slot,
                    "winner_model_canonical": A.canonical_model(
                        next((p["model_canonical"] for p in parts if p["slot"] == winner_slot), None))
                        if winner_slot else None,
                    "ranking": ranking},
        "reason_tags": [],
        "rationale": j.get("summary"),
        "divergences": None,
        "next_action": None,
        "failure_class": None, "failure_reason": None,
        "notes": "Winner/rank derived from per-arm verdict ordinal (strong-catch>catch>partial>miss); raw grades in participant.scores.",
        "backfilled": True,
    }]


def project(out=A.DECISIONS, quiet=False):
    """Project the eval review + diagnosis runs into the arena log; return a stats dict.

    Idempotent + cost-preserving. Eval arms are Agent-tool subagents so their tokens
    are unrecoverable (cost null) — see module docstring / README "Token sourcing"."""
    def say(*a):
        if not quiet:
            print(*a)

    pack_commit = A.git_head()
    rows = []
    for run in REVIEW_RUNS:
        rows += project_review(run, pack_commit)
    for run, case in DIAGNOSIS_RUNS.items():
        rows += project_diagnosis(run, case, pack_commit)

    total, added, updated = A.merge_write(rows, out)
    nrev = sum(1 for r in rows if r["source"] == "eval-review")
    ndia = sum(1 for r in rows if r["source"] == "eval-diagnosis")
    say(f"eval: {len(rows)} decisions ({nrev} review, {ndia} diagnosis) "
        f"-> +{added} new / {updated} updated; log now {total} rows")
    say("  NOTE: eval arm token counts are null — Agent-tool subagent usage is not persisted.")
    say("  run-2026-08-10b skipped (no blind judge was run).")
    if quiet:
        return {"source": "eval", "rows": len(rows), "added": added,
                "updated": updated, "total": total}
    wins = {}
    for r in rows:
        wm = r["outcome"]["winner_model_canonical"]
        w = r["outcome"]["winner_slot"]
        if r["source"] == "eval-review" and w:
            wins[r["participants"][0]["treatment"] if w == r["participants"][0]["slot"]
                 else r["participants"][1]["treatment"]] = wins.get(
                 r["participants"][0]["treatment"] if w == r["participants"][0]["slot"]
                 else r["participants"][1]["treatment"], 0) + 1
    if wins:
        print("  review winner by treatment: " + ", ".join(f"{k}={v}" for k, v in wins.items()))
    return {"source": "eval", "rows": len(rows), "added": added,
            "updated": updated, "total": total}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=A.DECISIONS)
    args = ap.parse_args()
    project(out=args.out)


if __name__ == "__main__":
    main()
