#!/usr/bin/env python3
"""Pure helpers for projecting an explicit exact-head human plan."""

from __future__ import annotations

from typing import Any


SCHEMA = "dev-pack-human-plan.v1"
ARCHIVE_SCHEMA = "dev-pack-human-plan-archive.v1"
WAIT_VALUES = ("ci", "author")
THEN_VALUES = ("approve", "request_changes", "re_review", "inspect")
VALID_COMBINATIONS = {
    "ci": {"approve", "request_changes", "re_review", "inspect"},
    "author": {"re_review", "inspect"},
}


def qualified(item: dict[str, Any]) -> str:
    return f"{item['rig']}/{item['id']}"


def evaluate_plan(raw: dict[str, Any] | None, item: dict[str, Any]) -> dict[str, Any] | None:
    if not raw or raw.get("schema") != SCHEMA:
        return None
    plan = dict(raw)
    wait_for = str(plan.get("wait_for") or "")
    then = str(plan.get("then") or "")
    github = item.get("github") or {}
    planned_head = str(plan.get("head_sha") or "")
    current_head = str(github.get("current_head_sha") or "")
    plan.update({
        "valid": wait_for in VALID_COMBINATIONS and then in VALID_COMBINATIONS.get(wait_for, set()),
        "current_head_sha": current_head or None,
        "head_matches": bool(planned_head and current_head and planned_head == current_head),
        "github_freshness": github.get("freshness"),
        "github_review_state": github.get("review_state"),
        "ci_state": github.get("ci_state"),
        "commands": {
            "cancel": f"gc dev-pack plan {qualified(item)} --cancel",
            "replace": f"gc dev-pack plan {qualified(item)} --wait-for {wait_for} --then {then.replace('_', '-')}",
        },
    })
    if not plan["valid"]:
        plan["state"] = "invalid"
    elif not github.get("available"):
        plan["state"] = "github-unavailable"
    elif wait_for == "author":
        plan["state"] = "waiting" if plan["head_matches"] else "ready"
    elif not plan["head_matches"]:
        plan["state"] = "head-drift"
    elif github.get("ci_state") == "passing":
        plan["state"] = "ready"
    elif github.get("ci_state") == "failing":
        plan["state"] = "ci-failing"
    else:
        plan["state"] = "waiting"
    if plan["state"] == "ready" and then in {"approve", "request_changes"}:
        plan["commands"]["reconcile_after_github"] = (
            f"gc dev-pack reconcile {qualified(item)} --as {then.replace('_', '-')}"
        )
    return plan


def archive_plan(archive: dict[str, Any] | None, plan: dict[str, Any], outcome: str,
                 archived_at: str) -> dict[str, Any]:
    """Retain immutable explicit-plan evidence when its active slot is replaced."""
    entries = list((archive or {}).get("plans") or []) if (archive or {}).get("schema") == ARCHIVE_SCHEMA else []
    durable = ("schema", "wait_for", "then", "head_sha", "github_url", "created_at", "note")
    record = {key: plan.get(key) for key in durable if key in plan}
    condition_satisfied = bool(plan.get("condition_satisfied") or plan.get("state") == "ready")
    record.update({"archived_outcome": outcome, "archived_at": archived_at})
    record["condition_satisfied"] = condition_satisfied
    if condition_satisfied:
        record["condition_satisfied_at"] = plan.get("condition_satisfied_at") or archived_at
    fingerprint = tuple(record.get(key) for key in ("schema", "wait_for", "then", "head_sha", "created_at"))
    entries = [entry for entry in entries if tuple(entry.get(key) for key in
               ("schema", "wait_for", "then", "head_sha", "created_at")) != fingerprint]
    entries.append(record)
    return {"schema": ARCHIVE_SCHEMA, "plans": entries}


def evaluate_archive(raw: dict[str, Any] | None, item: dict[str, Any]) -> list[dict[str, Any]]:
    if not raw or raw.get("schema") != ARCHIVE_SCHEMA:
        return []
    result = []
    for entry in raw.get("plans") or []:
        evaluated = evaluate_plan(entry, item) if isinstance(entry, dict) else None
        if not evaluated:
            continue
        if entry.get("condition_satisfied") and evaluated.get("valid") and evaluated.get("head_matches"):
            evaluated["state"] = "ready"
            if evaluated.get("then") in {"approve", "request_changes"}:
                evaluated["commands"]["reconcile_after_github"] = (
                    f"gc dev-pack reconcile {qualified(item)} --as {evaluated['then'].replace('_', '-')}"
                )
        result.append(evaluated)
    return result


def action_label(action: str) -> str:
    return {
        "approve": "Approve",
        "request_changes": "Request changes",
        "re_review": "Re-review",
        "inspect": "Inspect and decide",
    }.get(action, action.replace("_", " ").capitalize())
