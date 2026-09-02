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
        plan = item.get("human_plan")
        archived_plans = item.get("archived_human_plans") or []
        github = item.get("github") or {}
        if not github.get("available") or github.get("freshness") != "live":
            raise RuntimeError("a live GitHub observation is required; refresh was unavailable or stale")
        current = github.get("current_head_sha")
        metadata = bead.get("metadata") or {}
        terminal_state = (github.get("state") if github.get("kind") == "pull_request" and
                          github.get("state") in {"CLOSED", "MERGED"} else None)
        if terminal_state:
            if args.action:
                raise RuntimeError("--as records a review action and cannot be used for terminal PR completion")
            recorded = (metadata.get("gc.upstream_completion_state") == terminal_state and
                        metadata.get("gc.upstream_completion_sha") == current)
            already_closed = bead.get("status") == "closed"
            action = reviewed = expected = None
            if recorded and already_closed:
                changed = False
                message = f"already reconciled terminal {terminal_state.lower()} completion"
            elif args.dry_run:
                changed = False
                message = f"would reconcile terminal {terminal_state.lower()} completion"
            else:
                prefix = [gc, "--city", city]
                scope = item["rig"]
                if scope != "hq":
                    prefix += ["--rig", scope]
                if not recorded:
                    head_text = f" at head {current}" if current else " (head unavailable)"
                    note = (f"Observed live GitHub PR terminal state {terminal_state}{head_text}; "
                            "recorded upstream completion without inferring a review action.")
                    update = prefix + ["bd", "update", item["id"], "--append-notes", note,
                                       "--set-metadata", f"gc.upstream_completion_state={terminal_state}",
                                       "--unset-metadata", "gc.human_plan_json",
                                       "--remove-label", "wait:ci", "--remove-label", "wait:author"]
                    if current:
                        update += ["--set-metadata", f"gc.upstream_completion_sha={current}"]
                    else:
                        update += ["--unset-metadata", "gc.upstream_completion_sha"]
                    mutation = run(update)
                    if mutation.returncode:
                        raise RuntimeError(mutation.stderr.strip() or mutation.stdout.strip() or
                                           "bead completion update failed")
                if not already_closed:
                    reason = f"Live GitHub PR terminal state {terminal_state} observed"
                    mutation = run(prefix + ["bd", "close", item["id"], "--reason", reason])
                    if mutation.returncode:
                        raise RuntimeError(mutation.stderr.strip() or mutation.stdout.strip() or
                                           "bead completion close failed")
                changed = True
                message = f"recorded terminal {terminal_state.lower()} completion"
        else:
            planned_action = (plan or {}).get("then") if (plan or {}).get("then") in {"approve", "request_changes"} else None
            if args.action:
                action = args.action.replace("-", "_")
            elif planned_action:
                action = str(planned_action)
            elif (archived := next((candidate for candidate in reversed(archived_plans)
                                   if candidate.get("then") in {"approve", "request_changes"}
                                   and candidate.get("head_matches") and candidate.get("state") == "ready"
                                   and github.get("review_state") == ("APPROVED" if candidate.get("then") == "approve" else "CHANGES_REQUESTED")), None)):
                action = str(archived["then"])
            elif decision:
                action = str(decision["recommended_action"])
            else:
                raise RuntimeError("no actionable human plan or authoritative finished review is linked to this source bead")
        if not terminal_state and (current and metadata.get("gc.upstream_review_sha") == current and
                metadata.get("gc.upstream_review_action") == action):
            reviewed = current
            expected = "CHANGES_REQUESTED" if action == "request_changes" else "APPROVED"
            changed = False
            message = f"already reconciled {action.replace('_', '-')} on {reviewed[:8]}"
        elif not terminal_state:
            evidence_plan = plan
            if not evidence_plan:
                evidence_plan = next((candidate for candidate in reversed(archived_plans)
                                      if candidate.get("then") == action), None)
            if evidence_plan:
                plan = evidence_plan
                evidence_action = plan.get("then") if plan.get("then") in {"approve", "request_changes"} else None
                if not evidence_action:
                    raise RuntimeError("the active human plan does not end in an upstream review action")
                if action != evidence_action:
                    raise RuntimeError(f"the explicit human plan ends in {evidence_action.replace('_', '-')}; replace or cancel it before reconciling as {action.replace('_', '-')}")
                if plan.get("state") != "ready":
                    detail = ("CI is still pending" if plan.get("state") == "waiting" and plan.get("wait_for") == "ci"
                              else "CI is failing" if plan.get("state") == "ci-failing"
                              else "the planned exact head has changed" if plan.get("state") == "head-drift"
                              else "the plan condition is not satisfied")
                    raise RuntimeError(f"{detail}; do not reconcile the planned action yet")
                reviewed = plan.get("head_sha")
                evidence_ref = ("archived explicit human plan" if plan in archived_plans else "explicit human plan")
            else:
                if not decision:
                    raise RuntimeError("no authoritative finished PR review is linked to this source bead")
                reviewed = decision.get("reviewed_head_sha")
                if not reviewed:
                    raise RuntimeError("review evidence lacks the exact reviewed SHA; repeat the review")
                evidence_ref = str(decision.get("result_bead") or "durable review")
            if not current or current != reviewed:
                raise RuntimeError(f"head drift: GitHub {current or 'unknown'} does not match reviewed SHA {reviewed}")
            expected = "CHANGES_REQUESTED" if action == "request_changes" else "APPROVED"
            if github.get("review_state") != expected:
                raise RuntimeError(f"GitHub reports {github.get('review_state') or 'UNKNOWN'}, not {expected}; perform the GitHub action first")
            if args.dry_run:
                changed = False
                message = f"would reconcile {action.replace('_', '-')} on {reviewed[:8]}"
            else:
                prefix = [gc, "--city", city]
                scope = item["rig"]
                if scope != "hq":
                    prefix += ["--rig", scope]
                note = (f"Observed GitHub review {expected} on exact reviewed head {reviewed}; "
                        f"reconciled as {action.replace('_', '-')} from {evidence_ref}.")
                update = prefix + ["bd", "update", item["id"], "--append-notes", note,
                                   "--set-metadata", f"gc.upstream_review_sha={reviewed}",
                                   "--set-metadata", f"gc.upstream_review_action={action}",
                                   "--unset-metadata", "gc.human_plan_json",
                                   "--remove-label", "wait:ci", "--remove-label", "wait:author"]
                if action == "request_changes":
                    update += ["--status", "blocked"]
                    for label in ("needs-you", "needs_you", "action-required", "human-action",
                                  "blocked", "needs-re-review"):
                        update += ["--remove-label", label]
                    update += ["--add-label", "wait:author"]
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
              "completion_state": terminal_state, "completion_head_sha": current if terminal_state else None,
              "changed": changed, "dry_run": args.dry_run, "message": message}
    if args.json:
        json.dump(result, sys.stdout, indent=2, sort_keys=True); print()
    else:
        print(f"reconcile: {message} ({result['source']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
