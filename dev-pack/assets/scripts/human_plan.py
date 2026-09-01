#!/usr/bin/env python3
"""Pure helpers for projecting an explicit exact-head human plan."""

from __future__ import annotations

from typing import Any


SCHEMA = "dev-pack-human-plan.v1"
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
            "clear": f"gc dev-pack plan {qualified(item)} --clear",
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


def action_label(action: str) -> str:
    return {
        "approve": "Approve",
        "request_changes": "Request changes",
        "re_review": "Re-review",
        "inspect": "Inspect and decide",
    }.get(action, action.replace("_", " ").capitalize())
