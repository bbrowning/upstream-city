#!/usr/bin/env python3
"""Render upstream-ready feedback without mutating beads, mail, or GitHub."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

SCRIPTS = Path(__file__).resolve().parents[2] / "assets" / "scripts"
sys.path.insert(0, str(SCRIPTS))
from attention_decision import feedback_body  # noqa: E402


def parse_target(target: str, rig: str | None) -> tuple[str, str | None]:
    if "/" not in target:
        return target, rig
    qualified_rig, bead = target.split("/", 1)
    if not qualified_rig or not bead:
        raise ValueError("qualified target must be RIG/BEAD")
    if rig and rig != qualified_rig:
        raise ValueError(f"qualified target selects rig {qualified_rig!r}, conflicting with --rig {rig!r}")
    return bead, qualified_rig


def work_show(target: str, rig: str | None, mode: str | None) -> dict:
    work = Path(__file__).resolve().parents[1] / "work" / "run.py"
    command = [sys.executable, str(work), "show", target]
    if rig:
        command += ["--rig", rig]
    if mode:
        command.append(mode)
    command.append("--json")
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "work show failed")
    return json.loads(result.stdout)


def main() -> int:
    parser = argparse.ArgumentParser(prog="gc dev-pack feedback", description=__doc__)
    parser.add_argument("target", help="source bead, external ref, or qualified RIG/BEAD")
    parser.add_argument("--rig")
    parser.add_argument("--action", choices=("approve", "request-changes"))
    parser.add_argument("--json", action="store_true")
    network = parser.add_mutually_exclusive_group()
    network.add_argument("--refresh", action="store_true")
    network.add_argument("--no-network", action="store_true")
    args = parser.parse_args()
    try:
        target, rig = parse_target(args.target, args.rig)
        mode = "--refresh" if args.refresh else "--no-network" if args.no_network else None
        shown = work_show(target, rig, mode)
        decision = shown["item"].get("decision")
        if not decision:
            raise RuntimeError("no authoritative finished PR review is linked to this source bead")
        if not decision.get("reviewed_head_sha"):
            raise RuntimeError("review evidence lacks the exact reviewed SHA; repeat the review before rendering feedback")
        if decision.get("current_head_sha") and not decision.get("head_matches"):
            raise RuntimeError("GitHub head differs from the reviewed SHA; repeat the review before rendering feedback")
        action = (args.action or decision["recommended_action"]).replace("-", "_")
        body = feedback_body(decision, action)
    except (ValueError, RuntimeError, KeyError, json.JSONDecodeError) as exc:
        print(f"feedback: {exc}", file=sys.stderr)
        return 2
    if args.json:
        json.dump({"schema_version": "dev-pack-feedback.v1", "read_only": True,
                   "source": f"{shown['item']['rig']}/{shown['item']['id']}",
                   "action": action, "reviewed_head_sha": decision["reviewed_head_sha"],
                   "result_bead": decision["result_bead"], "body": body}, sys.stdout,
                  indent=2, sort_keys=True)
        print()
    else:
        print(body, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
