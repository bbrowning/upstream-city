#!/usr/bin/env python3
"""Persist only an explicitly requested human plan; never harvest ask sessions."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

SCRIPTS = Path(__file__).resolve().parents[2] / "assets" / "scripts"
sys.path.insert(0, str(SCRIPTS))
from human_plan import SCHEMA, VALID_COMBINATIONS, archive_plan  # noqa: E402


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


def work_show(target: str, rig: str | None, refresh: bool) -> dict:
    work = Path(__file__).resolve().parents[1] / "work" / "run.py"
    command = [sys.executable, str(work), "show", target]
    if rig:
        command += ["--rig", rig]
    command += ["--refresh" if refresh else "--no-network", "--json"]
    result = run(command)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "work show failed")
    return json.loads(result.stdout)


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="gc dev-pack plan",
        description="Explicitly remember a conditional human plan on the exact current PR head.",
        epilog=("Valid combinations: ci -> approve, request-changes, re-review, inspect; "
                "author -> re-review, inspect. Example: gc dev-pack plan vllm/source "
                "--wait-for ci --then approve --note 'Coverage is optional.'"),
    )
    p.add_argument("target", help="source bead, external ref, or qualified RIG/BEAD")
    p.add_argument("--rig")
    p.add_argument("--wait-for", choices=("ci", "author"), metavar="{ci,author}",
                   help="observable condition: CI completion or a new author head")
    p.add_argument("--then", dest="then_action",
                   choices=("approve", "request-changes", "re-review", "inspect"),
                   metavar="{approve,request-changes,re-review,inspect}",
                   help="next human action after the condition changes")
    p.add_argument("--note", help="optional free-form human context (not harvested from ask)")
    cancel = p.add_mutually_exclusive_group()
    cancel.add_argument("--cancel", dest="clear", action="store_true",
                        help="cancel the active plan without recording an upstream outcome")
    cancel.add_argument("--clear", dest="clear", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--dry-run", action="store_true", help="validate and show the change without mutating the bead")
    p.add_argument("--json", action="store_true")
    return p


def main() -> int:
    args = parser().parse_args()
    gc = os.environ.get("GC_BIN", "gc")
    city = os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY") or os.getcwd()
    try:
        target, rig = parse_target(args.target, args.rig)
        if args.clear:
            if args.wait_for or args.then_action or args.note:
                raise ValueError("--cancel cannot be combined with --wait-for, --then, or --note")
        else:
            if not args.wait_for or not args.then_action:
                raise ValueError("creating a plan requires both --wait-for and --then; use --help for choices")
            then = args.then_action.replace("-", "_")
            allowed = VALID_COMBINATIONS[args.wait_for]
            if then not in allowed:
                choices = ", ".join(sorted(value.replace("_", "-") for value in allowed))
                raise ValueError(f"--wait-for {args.wait_for} cannot be followed by {args.then_action}; valid choices: {choices}")
        shown = work_show(target, rig, refresh=True)
        item, bead = shown["item"], shown["evidence"]["bead"]
        metadata = bead.get("metadata") or {}
        existing_raw = metadata.get("gc.human_plan_json")
        try:
            existing = existing_raw if isinstance(existing_raw, dict) else json.loads(existing_raw) if existing_raw else None
        except json.JSONDecodeError:
            existing = None
        archive_raw = metadata.get("gc.human_plan_archive_json")
        try:
            archive = archive_raw if isinstance(archive_raw, dict) else json.loads(archive_raw) if archive_raw else None
        except json.JSONDecodeError:
            archive = None
        if args.clear:
            if existing:
                github = item.get("github") or {}
                expected = "CHANGES_REQUESTED" if existing.get("then") == "request_changes" else "APPROVED"
                observed_action = existing.get("then") in {"approve", "request_changes"} and github.get("review_state") == expected
                if github.get("state") in {"CLOSED", "MERGED"} or observed_action:
                    action = str(existing.get("then") or "").replace("_", "-")
                    suffix = f" --as {action}" if action in {"approve", "request-changes"} else ""
                    raise RuntimeError("GitHub already records the planned upstream outcome; reconcile it instead: "
                                       f"gc dev-pack reconcile {item['rig']}/{item['id']}{suffix}")
            plan = None
            changed = bool(existing)
            message = "would cancel plan" if args.dry_run and changed else "canceled plan" if changed else "no active plan"
        else:
            github = item.get("github") or {}
            if not github.get("available") or github.get("freshness") != "live" or github.get("kind") != "pull_request":
                raise RuntimeError("a live GitHub pull-request observation is required to pin the plan")
            head = github.get("current_head_sha")
            if not head:
                raise RuntimeError("GitHub did not provide the current exact head SHA")
            plan = {"schema": SCHEMA, "wait_for": args.wait_for, "then": then,
                    "head_sha": head, "github_url": github.get("url"),
                    "created_at": shown["generated_at"], "note": args.note or ""}
            equivalent = bool(existing and all(existing.get(key) == plan.get(key)
                              for key in ("schema", "wait_for", "then", "head_sha", "note")))
            changed = not equivalent
            message = ("plan already active" if equivalent else "would record plan" if args.dry_run else "recorded plan")
        if changed and not args.dry_run:
            prefix = [gc, "--city", city]
            if item["rig"] != "hq":
                prefix += ["--rig", item["rig"]]
            command = prefix + ["bd", "update", item["id"]]
            managed = ("wait:ci", "wait:author", "blocked", "needs-re-review",
                       "needs-you", "needs_you", "action-required", "human-action")
            for label in managed:
                command += ["--remove-label", label]
            if args.clear:
                archived = archive_plan(archive, item.get("human_plan") or existing, "canceled", shown["generated_at"])
                command += ["--set-metadata", "gc.human_plan_archive_json=" + json.dumps(archived, separators=(",", ":")),
                            "--unset-metadata", "gc.human_plan_json", "--status", "open"]
            else:
                if existing and changed:
                    archived = archive_plan(archive, item.get("human_plan") or existing, "replaced", shown["generated_at"])
                    command += ["--set-metadata", "gc.human_plan_archive_json=" + json.dumps(archived, separators=(",", ":"))]
                command += ["--set-metadata", "gc.human_plan_json=" + json.dumps(plan, separators=(",", ":")),
                            "--status", "blocked", "--add-label", f"wait:{args.wait_for}"]
            mutation = run(command)
            if mutation.returncode:
                raise RuntimeError(mutation.stderr.strip() or mutation.stdout.strip() or "plan update failed")
    except (ValueError, RuntimeError, KeyError, json.JSONDecodeError) as exc:
        print(f"plan: {exc}", file=sys.stderr)
        return 2
    result = {"schema_version": "dev-pack-plan.v1", "source": f"{item['rig']}/{item['id']}",
              "changed": changed and not args.dry_run, "dry_run": args.dry_run,
              "canceled": args.clear, "plan": plan, "message": message}
    if args.json:
        json.dump(result, sys.stdout, indent=2, sort_keys=True); print()
    else:
        print(f"plan: {message} ({result['source']})")
        if plan:
            print(f"  exact head: {plan['head_sha']}")
            print(f"  wait for:   {plan['wait_for']}")
            print(f"  then:       {plan['then'].replace('_', '-')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
