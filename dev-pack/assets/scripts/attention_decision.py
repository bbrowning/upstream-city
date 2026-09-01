#!/usr/bin/env python3
"""Pure helpers for turning durable review evidence into a human handoff."""

from __future__ import annotations

import datetime as dt
import json
import re
from typing import Any


def _time(value: str | None) -> dt.datetime:
    if not value:
        return dt.datetime.min.replace(tzinfo=dt.timezone.utc)
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(dt.timezone.utc)
    except ValueError:
        return dt.datetime.min.replace(tzinfo=dt.timezone.utc)


def _output(bead: dict[str, Any]) -> dict[str, Any] | None:
    raw = bead.get("metadata", {}).get("gc.output_json")
    if isinstance(raw, dict):
        return raw
    try:
        value = json.loads(raw) if raw else None
    except (TypeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def latest_review(children: list[dict[str, Any]]) -> tuple[dict[str, Any], dict[str, Any]] | None:
    candidates: dict[str, tuple[dt.datetime, bool, dict[str, Any], dict[str, Any]]] = {}
    for child in children:
        output = _output(child)
        schema = str(child.get("metadata", {}).get("gc.output_json_schema") or
                     (output or {}).get("schema") or "")
        if not output or not schema.startswith("pr-review") or not output.get("verdict"):
            continue
        stamp = _time(child.get("closed_at") or child.get("updated_at"))
        execution = str(child.get("metadata", {}).get("gc.kind") or "") not in {"retry", "control"}
        fingerprint = json.dumps(output, sort_keys=True, separators=(",", ":"))
        previous = candidates.get(fingerprint)
        # Retry controllers mirror the execution bead's durable output a few seconds
        # later. Keep that time for ordering between review rounds, but point humans
        # at the actual execution/result bead when both copies exist.
        if previous:
            group_stamp, group_execution, group_bead, group_output = previous
            representative = execution and not group_execution
            candidates[fingerprint] = (
                max(stamp, group_stamp), execution or group_execution,
                child if representative else group_bead,
                output if representative else group_output,
            )
        else:
            candidates[fingerprint] = (stamp, execution, child, output)
    if not candidates:
        return None
    _, _, bead, output = max(candidates.values(), key=lambda candidate: candidate[0])
    return bead, output


def build_decision(item: dict[str, Any], children: list[dict[str, Any]]) -> dict[str, Any] | None:
    latest = latest_review(children)
    if not latest:
        return None
    result_bead, output = latest
    verdict = str(output.get("verdict") or "")
    recommended = "approve" if verdict in {"approve", "approved", "approve_with_nits"} else "request_changes"
    github = item.get("github") or {}
    reviewed = github.get("reviewed_head_sha")
    current = github.get("current_head_sha")
    expected_state = "CHANGES_REQUESTED" if recommended == "request_changes" else "APPROVED"
    qualified = f"{item['rig']}/{item['id']}"
    feedback = f"gc dev-pack feedback {qualified}"
    reconcile = f"gc dev-pack reconcile {qualified}"
    summary_rig = "" if item["rig"] == "hq" else f" --rig {item['rig']}"
    full_review = f"gc dev-pack summary {result_bead.get('id')}{summary_rig} --full"
    if not github.get("available"):
        state = "github-unavailable"
    elif not reviewed:
        state = "review-required"
    elif not current or current != reviewed:
        state = "head-drift"
    elif github.get("review_state") == expected_state:
        state = "upstream-observed"
    else:
        state = "upstream-action-required"
    action_label = "Request changes" if recommended == "request_changes" else "Approve"
    opposite = "approve" if recommended == "request_changes" else "request_changes"
    opposite_label = "Approve" if opposite == "approve" else "Request changes"
    findings = [{key: finding.get(key) for key in ("severity", "title", "detail", "file", "line", "suggested_fix")}
                for finding in output.get("findings", []) if isinstance(finding, dict)]
    return {
        "state": state,
        "verdict": verdict,
        "recommended_action": recommended,
        "action_label": action_label,
        "expected_github_review_state": expected_state,
        "github_review_state": github.get("review_state"),
        "github_url": github.get("url"),
        "reviewed_head_sha": reviewed,
        "current_head_sha": current,
        "head_matches": bool(reviewed and current and reviewed == current),
        "result_bead": result_bead.get("id"),
        "result_schema": result_bead.get("metadata", {}).get("gc.output_json_schema"),
        "summary": output.get("summary") or "",
        "merge_recommendation": output.get("merge_recommendation") or "",
        "findings": findings,
        "commands": {
            "full_review": full_review,
            "render_feedback": feedback,
            "reconcile_after_github": reconcile,
            "disagree_render": f"{feedback} --action {opposite.replace('_', '-')}",
            "disagree_reconcile": f"{reconcile} --as {opposite.replace('_', '-')}",
        },
        "disagree_action_label": opposite_label,
    }


INTERNAL_FEEDBACK_MARKERS = re.compile(
    r"\b(?:arbiter|bead|harness|lane|persona|posture|provenance|re-synthesis|"
    r"reviewer [ab]|settle(?:d|ment)?)\b|co-authored-by",
    re.IGNORECASE,
)


def _clean_feedback_text(value: Any) -> str:
    """Drop internal workflow sentences while preserving author-actionable evidence."""
    text = str(value or "").strip()
    if not text:
        return ""
    sentences = re.split(r"(?<=[.!?])\s+", text)
    return " ".join(sentence for sentence in sentences
                    if not INTERNAL_FEEDBACK_MARKERS.search(sentence)).strip()


def feedback_body(decision: dict[str, Any], action: str | None = None) -> str:
    chosen = (action or decision["recommended_action"]).replace("-", "_")
    sha = decision.get("reviewed_head_sha") or "unknown"
    if chosen == "approve":
        lines = [f"Approved after review of `{sha}`.", ""]
        if chosen == decision.get("recommended_action"):
            notes = decision.get("findings") or []
            if notes:
                lines.append("Non-blocking notes:")
                for index, finding in enumerate(notes, 1):
                    lines.extend(_feedback_finding(index, finding))
                lines.append("")
        return "\n".join(lines).rstrip() + "\n"
    lines = [f"Requesting changes after review of `{sha}`.", ""]
    findings = decision.get("findings") or []
    if chosen == "request_changes":
        blocking = [finding for finding in findings if finding.get("severity") in {"blocker", "critical", "major"}]
        notes = [finding for finding in findings if finding not in blocking]
        for heading, selected in (("Requested changes", blocking or findings), ("Additional notes", notes if blocking else [])):
            if not selected:
                continue
            lines.append(heading + ":")
            for index, finding in enumerate(selected, 1):
                lines.extend(_feedback_finding(index, finding))
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _feedback_finding(index: int, finding: dict[str, Any]) -> list[str]:
    location = str(finding.get("file") or "")
    if finding.get("line") not in {None, ""}:
        location += f":{finding['line']}"
    lines = [f"{index}. {finding.get('title') or 'Finding'}" + (f" — {location}" if location else "")]
    detail = _clean_feedback_text(finding.get("detail"))
    suggested = _clean_feedback_text(finding.get("suggested_fix"))
    if detail:
        lines.append(f"   {detail}")
    if suggested:
        lines.append(f"   Suggested fix: {suggested}")
    return lines
