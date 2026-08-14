#!/usr/bin/env python3
"""Project PR-review quorum verdicts (pr-review-quorum.v1 synthesis beads) into the arena log.

Backfill AND going-forward capture, mirroring backfill_bug_lane.py. One row per quorum
RUN (grouped by the workflow `gc.root_bead_id`, which dedups the work bead + its
byte-identical logical/retry control bead). The synthesis bead's own `output_json.lanes[]`
is self-contained — it carries each lane's model + verdict + findings and the combined
call — so a row is built entirely from the synthesis bead and does NOT depend on the
per-lane beads surviving.

The "judge" is the quorum synthesis, whose criterion is a RULE, not a quality call:
the strictest lane verdict prevails (a real blocker found by ANY lane blocks the merge),
blocked > request_changes > approve_with_nits > approve. So:
  * aligned run  (both lanes same verdict)  -> no discriminating signal, winner = none
  * diverged run (lanes disagree)           -> winner = the lane whose (stricter) verdict
                                               became the combined call
This captures the useful model-vs-model signal (e.g. sonnet request_changes prevailing
over opus approve_with_nits on PR 51937).

Solo (N=1) reviews emit pr-review.v1, not the quorum schema, so they never appear here —
there is no comparison to rate. Per-lane token/cost is deferred (see the review-lane
live-capture bead); participants carry model/effort/verdict but cost=None for now.

Usage:  python3 backfill_review_quorum.py [--export path] [--out path]
"""
import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import arena_common as A

REPO = A.REPO
RIG_DIR = os.path.join(REPO, "rigs", "vllm")
QUORUM_SCHEMA = "pr-review-quorum.v1"

# strictest-first ranking the synthesis uses to combine lane verdicts
VERDICT_RANK = {"blocked": 3, "request_changes": 2, "approve_with_nits": 1, "approve": 0}


def meta(b, k, default=None):
    return (b.get("metadata") or {}).get(k, default)


# ---- resolve a lane's model/effort ------------------------------------------
# lanes[].model is a free-form string that varies across pack versions: an agent-name
# profile ("vllm/pr-reviewer-opus48-xhigh" — the name fully identifies the model), a
# model id + effort ("claude-opus-4-6 (xhigh)"), a slug ("opus-4.6-xhigh"), or a bare
# family ("claude"/"sonnet"). model_canonical (the family) is the arena's comparison key
# and is always recoverable via A.canonical_model; model_resolved is best-effort provenance.
# (city.toml is NOT consulted — its multi-line inline tables aren't strict-TOML parseable,
# and the profile name is a more reliable identifier anyway.)
def _canon_effort(s):
    s = (s or "").lower()
    for e in ("xhigh", "max", "high", "medium", "low"):   # xhigh before high (substring)
        if e in s:
            return e
    return None


def resolve_lane_model(raw):
    """-> (agent, model_resolved, effort, model_canonical) from a free-form lane.model."""
    raw = (raw or "").strip()
    short = raw.split("/")[-1].rstrip(")")       # tolerate stray "pr-reviewer-b)" artifacts
    if "pr-reviewer-" in short:                  # a profile name — it fully identifies the model
        return short, short, _canon_effort(short), A.canonical_model(short)
    # a model id / slug, possibly with a trailing effort suffix
    model = re.sub(r"\s*\(?(x?high|max|medium|low)\)?\s*$", "", raw).strip().rstrip("-").strip() or raw
    return None, model, _canon_effort(raw), A.canonical_model(raw)


def build_participants(lanes):
    parts = []
    for ln in lanes:
        agent, model_resolved, effort, canon = resolve_lane_model(ln.get("model"))
        parts.append({
            "slot": ln.get("lane_id"),
            "agent": agent,
            "model_intent": ln.get("model"),        # raw string as recorded by the run
            "model_resolved": model_resolved,
            "model_canonical": canon,
            "effort_resolved": effort,
            "verdict": ln.get("verdict"),
            "findings_count": ln.get("findings_count"),
            "effective_posture": ln.get("effective_posture"),
            "cost": None,                            # per-lane tokens deferred (live-capture bead)
            "cost_source": None,
        })
    return parts


def project(export=None, out=A.DECISIONS, quiet=False):
    """Project pr-review-quorum decisions into the arena log; return a stats dict.

    Idempotent (merges by decision_id via A.merge_write). Refresh-compatible: same
    (export, out, quiet) signature as the other projectors, so wiring it into
    arena_refresh.PROJECTORS is a one-liner."""
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

    # group synthesis beads by workflow root (dedups the work + control-bead pair)
    by_root = defaultdict(list)
    skipped = 0
    for b in beads:
        if meta(b, "gc.output_json_schema") != QUORUM_SCHEMA:
            continue
        raw = meta(b, "gc.output_json")
        if not raw:
            skipped += 1
            continue
        try:
            oj = json.loads(raw)
        except (json.JSONDecodeError, TypeError):
            skipped += 1
            continue
        root = meta(b, "gc.root_bead_id") or b["id"]
        by_root[root].append((b, oj))

    pack_commit = A.git_head()
    rows = []
    for root, members in sorted(by_root.items()):
        members = sorted(members, key=lambda m: m[0]["id"])
        rep, oj = members[0]
        lanes = oj.get("lanes") or []
        if len(lanes) < 2:                       # need a real comparison
            skipped += 1
            continue
        parts = build_participants(lanes)
        verdicts = [p["verdict"] for p in parts]
        aligned = len(set(verdicts)) == 1
        combined = oj.get("verdict")
        winner_slot = winner_canon = None
        if not aligned:
            cands = [p for p in parts if p["verdict"] == combined]
            if len(cands) == 1:
                winner_slot = cands[0]["slot"]
                winner_canon = cands[0]["model_canonical"]

        rows.append({
            "schema": A.ARENA_SCHEMA,
            "decision_id": f"{root}:review",
            "source": "pr-review-quorum",
            "source_refs": [m[0]["id"] for m in members],
            "root_bead": root,
            "subject_ref": f"PR {oj.get('head_ref') or oj.get('pr') or '?'}",
            "subject_model": None,
            "lane": "review",
            "phase": "review",
            "round": None,
            "at": rep.get("created_at"),
            "pack_commit": pack_commit,              # git HEAD at projection; pinned on re-run
            "blind": False,                          # synthesis sees lane labels + models
            "mode": "pairwise",
            "judge": {"kind": "quorum-synthesis", "agent": (meta(rep, "gc.routed_to") or "").split("/")[-1] or None,
                      "provider": "claude", "model": None, "effort": None},
            "criterion": "strictest lane verdict prevails (a real blocker by any lane blocks the merge)",
            "aligned": aligned,
            "tie": False,                            # review always adopts a combined verdict
            "participants": parts,
            "outcome": {"winner_slot": winner_slot,
                        "winner_model_canonical": winner_canon,
                        "combined_verdict": combined,
                        "combined_findings_count": oj.get("findings_count"),
                        "ranking": None},
            "reason_tags": ["diverged"] if not aligned else ["aligned"],
            "rationale": oj.get("merge_recommendation") or oj.get("summary"),
            "divergences": None if aligned else
                           "; ".join(f"{p['slot']}({p['model_canonical']})={p['verdict']}" for p in parts),
            "next_action": None,
            "failure_class": "none",
            "failure_reason": "",
            "notes": None,
            "backfilled": True,
        })

    total, added, updated = A.merge_write(rows, out)
    say(f"\npr-review-quorum: {len(rows)} decisions projected ({skipped} skipped) "
        f"-> +{added} new / {updated} updated; log now {total} rows")
    if not quiet:
        _summary(rows)
    return {"source": "pr-review-quorum", "rows": len(rows), "added": added,
            "updated": updated, "total": total, "skipped": skipped}


def _summary(rows):
    diverged = [r for r in rows if not r["aligned"]]
    wins = defaultdict(int)
    for r in diverged:
        wm = r["outcome"]["winner_model_canonical"]
        if wm:
            wins[wm] += 1
    print(f"  runs {len(rows)}  aligned {len(rows) - len(diverged)}  diverged {len(diverged)}")
    if wins:
        print("  diverged-run winner by model: " +
              ", ".join(f"{m}={c}" for m, c in sorted(wins.items(), key=lambda x: -x[1])))
    for r in diverged:
        print(f"    {r['subject_ref']}: {r['divergences']} -> {r['outcome']['combined_verdict']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", help="pre-exported beads JSONL (else runs gc bd export)")
    ap.add_argument("--out", default=A.DECISIONS)
    args = ap.parse_args()
    project(export=args.export, out=args.out)


if __name__ == "__main__":
    main()
