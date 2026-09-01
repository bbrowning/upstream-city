#!/usr/bin/env python3
"""Reconcile a human-submitted GitHub review onto its source bead."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def parse_target(target: str, rig: str | None) -> tuple[str, str | None]:
    if "/" not in target:
        return target, rig
    qualified_rig, bead = target.split("/", 1)
    if not qualified_rig or not bead:
        raise ValueError("qualified target must be RIG/BEAD")
    if rig and rig != qualified_rig:
        raise ValueError(f"qualified target selects rig {qualified_rig!r}, conflicting with --rig {rig!r}")
    return bead, qualified_rig


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def main() -> int:
    parser = argparse.ArgumentParser(prog="gc dev-pack reconcile", description=__doc__)
    parser.add_argument("target", help="source bead, external ref, or qualified RIG/BEAD")
    parser.add_argument("--rig")
    parser.add_argument("--as", dest="action", choices=("approve", "request-changes"))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    gc = os.environ.get("GC_BIN", "gc")
    city = os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY") or os.getcwd()
    try:
        target, rig = parse_target(args.target, args.rig)
        work = Path(__file__).resolve().parents[1] / "work" / "run.py"
        command = [sys.executable, str(work), "show", target]
        if rig:
            command += ["--rig", rig]
        probe = run(command + ["--refresh", "--json"])
        if probe.returncode:
            raise RuntimeError(probe.stderr.strip() or probe.stdout.strip() or "work show refresh failed")
        shown = json.loads(probe.stdout)
        item, bead = shown["item"], shown["evidence"]["bead"]
        decision = item.get("decision")
        if not decision:
            raise RuntimeError("no authoritative finished PR review is linked to this source bead")
        github = item.get("github") or {}
        if not github.get("available") or github.get("freshness") != "live":
            raise RuntimeError("a live GitHub observation is required; refresh was unavailable or stale")
        reviewed, current = decision.get("reviewed_head_sha"), decision.get("current_head_sha")
        if not reviewed:
            raise RuntimeError("review evidence lacks the exact reviewed SHA; repeat the review")
        if not current or current != reviewed:
            raise RuntimeError(f"head drift: GitHub {current or 'unknown'} does not match reviewed SHA {reviewed}")
        action = (args.action or decision["recommended_action"]).replace("-", "_")
        expected = "CHANGES_REQUESTED" if action == "request_changes" else "APPROVED"
        if github.get("review_state") != expected:
            raise RuntimeError(f"GitHub reports {github.get('review_state') or 'UNKNOWN'}, not {expected}; perform the GitHub action first")
        metadata = bead.get("metadata") or {}
        if (metadata.get("gc.upstream_review_sha") == reviewed and
                metadata.get("gc.upstream_review_action") == action):
            changed = False
            message = f"already reconciled {action.replace('_', '-')} on {reviewed[:8]}"
        elif args.dry_run:
            changed = False
            message = f"would reconcile {action.replace('_', '-')} on {reviewed[:8]}"
        else:
            prefix = [gc, "--city", city]
            scope = item["rig"]
            if scope != "hq":
                prefix += ["--rig", scope]
            note = (f"Observed GitHub review {expected} on exact reviewed head {reviewed}; "
                    f"reconciled as {action.replace('_', '-')} from {decision.get('result_bead')}.")
            update = prefix + ["bd", "update", item["id"], "--append-notes", note,
                               "--set-metadata", f"gc.upstream_review_sha={reviewed}",
                               "--set-metadata", f"gc.upstream_review_action={action}"]
            if action == "request_changes":
                update += ["--status", "blocked", "--add-label", "wait:author"]
                for label in ("needs-you", "needs_you", "action-required", "human-action",
                              "blocked", "needs-re-review"):
                    update += ["--remove-label", label]
                mutation = run(update)
            else:
                mutation = run(update)
                if mutation.returncode == 0:
                    mutation = run(prefix + ["bd", "close", item["id"], "--reason",
                                              f"GitHub approval observed on reviewed head {reviewed}"])
            if mutation.returncode:
                raise RuntimeError(mutation.stderr.strip() or mutation.stdout.strip() or "bead reconciliation failed")
            changed = True
            message = ("recorded waiting on author" if action == "request_changes"
                       else "recorded completion after GitHub approval")
    except (ValueError, RuntimeError, KeyError, json.JSONDecodeError) as exc:
        print(f"reconcile: {exc}", file=sys.stderr)
        return 2
    result = {"schema_version": "dev-pack-reconcile.v1", "source": f"{item['rig']}/{item['id']}",
              "action": action, "reviewed_head_sha": reviewed, "github_review_state": expected,
              "changed": changed, "dry_run": args.dry_run, "message": message}
    if args.json:
        json.dump(result, sys.stdout, indent=2, sort_keys=True); print()
    else:
        print(f"reconcile: {message} ({result['source']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
