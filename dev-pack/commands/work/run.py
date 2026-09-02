#!/usr/bin/env python3
"""Read-only human-attention projection for dev-pack work."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any

ASSETS_SCRIPTS = Path(__file__).resolve().parents[2] / "assets" / "scripts"
sys.path.insert(0, str(ASSETS_SCRIPTS))
from attention_decision import build_decision  # noqa: E402
from human_plan import action_label as plan_action_label, evaluate_archive, evaluate_plan  # noqa: E402


GROUPS = (
    ("needs-you", "NEEDS YOU"),
    ("in-flight", "IN FLIGHT"),
    ("waiting", "WAITING ON OTHERS"),
    ("stale-unclear", "STALE OR UNCLEAR"),
    ("recently-finished", "RECENTLY FINISHED"),
)
GROUP_KEYS = {key for key, _ in GROUPS}
ATTENTION_LABELS = {"human-facing", "attention", "attention=true", "maintainer"}
NEEDS_LABELS = {"needs-you", "needs_you", "action-required", "human-action"}
INTERNAL_TYPES = {"message", "gate"}
INTERNAL_LABEL_PREFIXES = (
    "gc:step", "gc:retry", "order:", "agent:", "role:", "message:", "gate:",
)
WAIT_LABEL_PREFIXES = (
    "wait:", "waiting:", "waiting-on:", "hold:", "blocked:",
)
FINAL_OUTPUT_PREFIXES = ("pr-review", "local-change", "feature-dev")
CACHE_SCHEMA = "dev-pack-github-cache.v1"
CACHE_LIMIT = 128
GITHUB_QUERY_LIMIT = 64
DEFAULT_CACHE_TTL = 1800


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(dt.timezone.utc)
    except ValueError:
        return None


def duration(value: str) -> dt.timedelta:
    units = {"h": 3600, "d": 86400, "w": 604800}
    try:
        return dt.timedelta(seconds=int(value[:-1]) * units[value[-1]])
    except (KeyError, ValueError):
        raise argparse.ArgumentTypeError("use a whole-number duration such as 12h, 7d, or 2w")


def bounded_env(name: str, default: int, maximum: int) -> int:
    try:
        return max(0, min(int(os.environ.get(name, str(default))), maximum))
    except ValueError:
        return default


def compact_age(seconds: int) -> str:
    seconds = max(0, seconds)
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h"
    return f"{seconds // 86400}d"


def run_json(argv: list[str]) -> Any:
    result = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise RuntimeError(f"{' '.join(argv)}: {detail}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"{' '.join(argv)} returned invalid JSON: {exc}") from exc


def metadata_json(bead: dict[str, Any], key: str) -> dict[str, Any] | None:
    raw = bead.get("metadata", {}).get(key)
    if not raw:
        return None
    if isinstance(raw, dict):
        return raw
    try:
        value = json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def output_schema(bead: dict[str, Any], output: dict[str, Any] | None) -> str:
    metadata = bead.get("metadata", {})
    return str(metadata.get("gc.output_json_schema") or (output or {}).get("schema") or
               (output or {}).get("schema_version") or "")


def labels(bead: dict[str, Any]) -> set[str]:
    return {str(label).lower() for label in bead.get("labels", [])}


def is_internal(bead: dict[str, Any]) -> bool:
    bead_labels = labels(bead)
    metadata = bead.get("metadata", {})
    if bead.get("issue_type") in INTERNAL_TYPES:
        return True
    if any(any(label.startswith(prefix) for prefix in INTERNAL_LABEL_PREFIXES)
           for label in bead_labels):
        return True
    return any(key in metadata for key in (
        "gc.step_id", "gc.step_ref", "gc.logical_bead_id", "gc.control_for",
        "gc.order_name", "gc.kind",
    ))


def is_marked(bead: dict[str, Any]) -> bool:
    bead_labels = labels(bead)
    if "attention=false" in bead_labels or "human-facing=false" in bead_labels:
        return False
    return bool(bead_labels & ATTENTION_LABELS)


def is_human_owned(bead: dict[str, Any], actors: set[str]) -> bool:
    values = {str(bead.get("owner", "")).casefold(), str(bead.get("assignee", "")).casefold()}
    return bool(values & actors)


def wait_reason(bead: dict[str, Any]) -> str | None:
    bead_labels = sorted(labels(bead))
    for label in bead_labels:
        if label in {"blocked", "waiting"} or label.startswith(WAIT_LABEL_PREFIXES):
            return label.replace(":", " ", 1)
    metadata = bead.get("metadata", {})
    hold = metadata.get("hold") or metadata.get("gc.hold")
    if hold:
        return f"hold {hold}"
    dependencies = [dep for dep in bead.get("dependencies", [])
                    if dep.get("type") == "blocks"]
    if dependencies:
        ids = ", ".join(str(dep.get("depends_on_id", "?")) for dep in dependencies[:3])
        return f"unresolved dependency {ids}"
    if bead.get("status") in {"blocked", "deferred"}:
        return f"canonical status is {bead['status']}"
    return None


def workflow_children(bead: dict[str, Any], all_beads: list[dict[str, Any]]) -> list[dict[str, Any]]:
    bead_id = bead.get("id")
    external_ref = str(bead.get("external_ref") or "")
    external_number = external_ref[3:] if external_ref.startswith("gh-") else ""
    found: list[dict[str, Any]] = []
    for child in all_beads:
        metadata = child.get("metadata", {})
        output = metadata_json(child, "gc.output_json")
        same_external_review = bool(
            external_number and output and str(output.get("head_ref") or "") == external_number and
            output_schema(child, output).startswith("pr-review")
        )
        if (child.get("parent") == bead_id or metadata.get("gc.root_bead_id") == bead_id or
                metadata.get("gc.human_source_bead") == bead_id or
                same_external_review):
            found.append(child)
    return found


def local_artifact(lifecycle: dict[str, Any] | None, rig_path: str) -> dict[str, Any] | None:
    if not lifecycle:
        return None
    branch = lifecycle.get("branch") or lifecycle.get("local_branch")
    expected = lifecycle.get("head_sha")
    result: dict[str, Any] = {
        key: lifecycle[key] for key in ("artifact_id", "branch", "head_sha", "revision", "disposition")
        if key in lifecycle
    }
    if not branch or not expected or not Path(rig_path, ".git").exists():
        return result or None
    probe = subprocess.run(
        ["git", "-C", rig_path, "rev-parse", "--verify", f"refs/heads/{branch}"],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    actual = probe.stdout.strip() if probe.returncode == 0 else ""
    result.update({
        "branch_present": bool(actual),
        "actual_head_sha": actual or None,
        "matches_recorded_head": bool(actual and actual == expected),
    })
    return result


def rig_arg(rig: str) -> str:
    return "" if rig == "hq" else f" --rig {rig}"


def authoritative_pointer(rig: str, bead: dict[str, Any], schema: str) -> str:
    rig_arg = "" if rig == "hq" else f" --rig {rig}"
    if schema.startswith("pr-review"):
        return f"gc dev-pack summary {bead['id']}{rig_arg}"
    if schema == "hard-bug-state.v1":
        return f"gc dev-pack status {bead['id']}{rig_arg}"
    return f"gc{rig_arg} bd show {bead['id']}"


def retrieval_paths(rig: str, bead: dict[str, Any], children: list[dict[str, Any]]) -> dict[str, Any]:
    arg = rig_arg(rig)
    result = [f"gc dev-pack work show {bead['id']}{arg}"]
    for child in children:
        output = metadata_json(child, "gc.output_json")
        schema = output_schema(child, output)
        if schema.startswith("pr-review"):
            result.append(f"gc dev-pack summary {child['id']}{arg}")
        elif schema == "hard-bug-state.v1":
            result.append(f"gc dev-pack status {child['id']}{arg}")
    return {"work_show": result[0], "summary_or_status": list(dict.fromkeys(result[1:]))}


def reviewed_head(children: list[dict[str, Any]]) -> tuple[str | None, str | None]:
    candidates: list[tuple[dt.datetime, str]] = []
    for child in children:
        metadata = child.get("metadata", {})
        output = metadata_json(child, "gc.output_json")
        if not output_schema(child, output).startswith("pr-review"):
            continue
        evidence = (output or {}).get("evidence")
        nested_sha = evidence.get("reviewed_head_sha") if isinstance(evidence, dict) else None
        sha = str(metadata.get("gc.reviewed_head_sha") or (output or {}).get("reviewed_head_sha") or
                  nested_sha or "")
        if sha:
            candidates.append((parse_time(child.get("closed_at") or child.get("updated_at")) or dt.datetime.min.replace(tzinfo=dt.timezone.utc), sha))
    if not candidates:
        return None, "legacy review evidence does not record the exact reviewed SHA"
    return max(candidates)[1], None


def repository_slug(path: str) -> str | None:
    probe = subprocess.run(["git", "-C", path, "remote", "get-url", "origin"], text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if probe.returncode:
        return None
    match = re.search(r"(?:github\.com[:/])([^/]+/[^/]+?)(?:\.git)?$", probe.stdout.strip())
    return match.group(1) if match else None


def cache_file(city: str, rig: str, external_ref: str) -> Path:
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", external_ref)
    return Path(city, ".gc", "cache", "dev-pack-work", "github", f"{rig}-{safe}.json")


def read_cache(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    return value if value.get("schema_version") == CACHE_SCHEMA else None


def write_cache(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".refresh-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    entries = sorted(path.parent.glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True)
    for old in entries[CACHE_LIMIT:]:
        old.unlink(missing_ok=True)


def github_observation(city: str, rig: str, rig_path: str, external_ref: str, now: dt.datetime,
                       refresh: bool, no_network: bool) -> dict[str, Any]:
    path = cache_file(city, rig, external_ref)
    cached = read_cache(path)
    ttl = bounded_env("DEV_PACK_WORK_CACHE_TTL", DEFAULT_CACHE_TTL, 86400)
    observed = parse_time((cached or {}).get("observed_at"))
    age = int((now - observed).total_seconds()) if observed else None
    fresh = age is not None and age <= ttl
    use_cache = cached is not None and (no_network or (fresh and not refresh))
    if use_cache:
        result = dict(cached["github"])
        result["freshness"] = "fresh-cache" if fresh else "stale-cache-no-network"
        result["cache_age_seconds"] = age
        return result
    if no_network:
        return {"authority": "GitHub", "available": False, "freshness": "unavailable-no-network",
                "observed_at": None, "error": "no cached GitHub observation"}
    slug = repository_slug(rig_path)
    number = external_ref[3:] if external_ref.startswith("gh-") else ""
    if not slug or not number.isdigit():
        return {"authority": "GitHub", "available": False, "freshness": "unavailable",
                "observed_at": None, "error": "could not resolve GitHub repository or PR number"}
    command = [os.environ.get("GH_BIN", "gh"), "pr", "view", number, "--repo", slug, "--json",
               "state,headRefOid,reviewDecision,statusCheckRollup,mergedAt,isDraft,updatedAt,url"]
    try:
        probe = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=bounded_env("DEV_PACK_WORK_GITHUB_TIMEOUT", 20, 60))
    except subprocess.TimeoutExpired:
        probe = subprocess.CompletedProcess(command, 124, "", "GitHub query timed out")
    if probe.returncode == 0:
        raw = json.loads(probe.stdout)
        checks = raw.get("statusCheckRollup") or []
        states = [str(check.get("conclusion") or check.get("state") or "UNKNOWN") for check in checks]
        github = {"authority": "GitHub", "kind": "pull_request", "available": True, "freshness": "live",
                  "observed_at": now.isoformat().replace("+00:00", "Z"), "url": raw.get("url"),
                  "state": raw.get("state"), "merged_at": raw.get("mergedAt"),
                  "draft": raw.get("isDraft"), "current_head_sha": raw.get("headRefOid"),
                  "review_state": raw.get("reviewDecision") or "UNKNOWN",
                  "ci_state": ("none" if not states else ("passing" if all(s in {"SUCCESS", "SKIPPED", "NEUTRAL"} for s in states)
                               else "pending" if any(s in {"", "UNKNOWN", "PENDING", "QUEUED", "IN_PROGRESS"} for s in states) else "failing")),
                  "source_updated_at": raw.get("updatedAt")}
        write_cache(path, {"schema_version": CACHE_SCHEMA, "observed_at": github["observed_at"], "github": github})
        return github
    issue_command = [os.environ.get("GH_BIN", "gh"), "issue", "view", number, "--repo", slug,
                     "--json", "state,updatedAt,url"]
    try:
        issue_probe = subprocess.run(issue_command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     timeout=bounded_env("DEV_PACK_WORK_GITHUB_TIMEOUT", 20, 60))
    except subprocess.TimeoutExpired:
        issue_probe = subprocess.CompletedProcess(issue_command, 124, "", "GitHub issue query timed out")
    if issue_probe.returncode == 0:
        raw = json.loads(issue_probe.stdout)
        github = {"authority": "GitHub", "kind": "issue", "available": True, "freshness": "live",
                  "observed_at": now.isoformat().replace("+00:00", "Z"), "url": raw.get("url"),
                  "state": raw.get("state"), "merged_at": None, "draft": None,
                  "current_head_sha": None, "review_state": "NOT_APPLICABLE", "ci_state": "NOT_APPLICABLE",
                  "source_updated_at": raw.get("updatedAt")}
        write_cache(path, {"schema_version": CACHE_SCHEMA, "observed_at": github["observed_at"], "github": github})
        return github
    if cached:
        result = dict(cached["github"])
        result.update({"freshness": "stale-cache-refresh-failed", "cache_age_seconds": age,
                       "refresh_error": probe.stderr.strip() or "GitHub query failed"})
        return result
    return {"authority": "GitHub", "available": False, "freshness": "unavailable",
            "observed_at": now.isoformat().replace("+00:00", "Z"),
            "error": issue_probe.stderr.strip() or probe.stderr.strip() or "GitHub query failed"}


def classify(bead: dict[str, Any], children: list[dict[str, Any]], now: dt.datetime,
             rig: str, rig_path: str, github: dict[str, Any] | None = None) -> dict[str, Any] | None:
    status = bead.get("status", "open")
    changed = parse_time(bead.get("closed_at") if status == "closed" else bead.get("updated_at"))
    changed = changed or parse_time(bead.get("created_at")) or now
    age_seconds = max(0, int((now - changed).total_seconds()))
    output = metadata_json(bead, "gc.output_json")
    lifecycle = metadata_json(bead, "gc.lifecycle_json")
    schema = output_schema(bead, output)
    artifact = local_artifact(lifecycle, rig_path)
    child_outputs = [child for child in children if metadata_json(child, "gc.output_json")]
    final_output_children = [
        child for child in child_outputs
        if output_schema(child, metadata_json(child, "gc.output_json")).startswith(FINAL_OUTPUT_PREFIXES)
    ]
    final_times = [
        timestamp for child in final_output_children
        if (timestamp := parse_time(child.get("closed_at") or child.get("updated_at"))) is not None
    ]
    latest_final = max(final_times, default=None)
    final_after_human_update = bool(latest_final and latest_final > changed)
    active_children = [child for child in children if child.get("status") in {"open", "in_progress", "blocked"}]

    reason: str
    next_action: str
    bead_labels = labels(bead)
    reviewed_sha, reviewed_uncertainty = reviewed_head(children)
    if github is not None:
        github["reviewed_head_sha"] = reviewed_sha
        github["changed_since_review"] = (None if not reviewed_sha or not github.get("current_head_sha")
                                            else reviewed_sha != github.get("current_head_sha"))
        github["reviewed_head_uncertainty"] = reviewed_uncertainty
    if status == "closed":
        group = "recently-finished"
        reason = "the human-facing bead itself is closed"
        next_action = "none; reopen only if the human disposition changes"
    elif (github and github.get("available") and github.get("kind") == "pull_request" and
          github.get("state") in {"CLOSED", "MERGED"}):
        group = "needs-you"
        reason = f"GitHub reports the PR {str(github.get('state')).lower()} while the human disposition remains open"
        next_action = "reconcile and record the human disposition; external closure never closes this bead"
    elif github and github.get("available") and github.get("changed_since_review") is True:
        group = "needs-you"
        reason = "the current exact GitHub head differs from the exact reviewed head"
        next_action = "review the new author head and record a human disposition"
    elif github is not None and reviewed_uncertainty and any(output_schema(child, metadata_json(child, "gc.output_json")).startswith("pr-review") for child in children):
        group = "needs-you"
        reason = reviewed_uncertainty
        next_action = "refresh or repeat review to establish exact-head evidence, then record a disposition"
    elif bead_labels & NEEDS_LABELS:
        group = "needs-you"
        reason = f"explicit human-action marker: {sorted(bead_labels & NEEDS_LABELS)[0]}"
        next_action = "review the authoritative evidence and record a disposition"
    elif final_after_human_update:
        group = "needs-you"
        reason = "automation produced durable final evidence after the last recorded human disposition"
        next_action = "review the new result and record a fresh human disposition on the source bead"
    elif (waiting := wait_reason(bead)) is not None:
        group = "waiting"
        reason = waiting
        next_action = "revisit when the recorded wait condition changes"
    elif (schema.startswith(FINAL_OUTPUT_PREFIXES) or
          (lifecycle and lifecycle.get("disposition") in {"approved", "request_changes", "escalated"}) or
          (schema == "hard-bug-state.v1" and (output or {}).get("status") in
           {"complete", "completed", "report_only_complete", "exhausted", "escalated"}) or
          any(output_schema(child, metadata_json(child, "gc.output_json")).startswith(FINAL_OUTPUT_PREFIXES)
              for child in child_outputs)):
        group = "needs-you"
        reason = "automation produced durable final evidence while the human-facing bead remains open"
        next_action = "review the result and record the human disposition on the source bead"
    elif artifact and artifact.get("branch_present") is False:
        group = "needs-you"
        reason = "the durable lifecycle points to a local branch that is no longer present"
        next_action = "inspect the lifecycle evidence and recover or retire the local change"
    elif artifact and artifact.get("matches_recorded_head") is False:
        group = "needs-you"
        reason = "the local branch no longer matches the lifecycle's recorded immutable head"
        next_action = "inspect branch drift and create a new artifact revision if intentional"
    elif (status == "in_progress" or active_children or
          (schema == "hard-bug-state.v1" and (output or {}).get("status") == "running")):
        group = "in-flight"
        if active_children:
            reason = f"{len(active_children)} active workflow child(ren) derive from this source bead"
        else:
            reason = "canonical status is in_progress"
        next_action = "monitor the active workflow; intervene only if its evidence stalls"
    else:
        group = "stale-unclear"
        reason = "open work has no active workflow, final result, or trustworthy explicit wait"
        next_action = "start it, record a canonical wait, defer it, or close it"

    item = {
        "group": group,
        "rig": rig,
        "id": bead.get("id"),
        "external_ref": bead.get("external_ref"),
        "title": bead.get("title", ""),
        "status": status,
        "priority": bead.get("priority"),
        "issue_type": bead.get("issue_type"),
        "owner": bead.get("owner"),
        "assignee": bead.get("assignee"),
        "reason": reason,
        "next_action": next_action,
        "age_seconds": age_seconds,
        "age": compact_age(age_seconds),
        "freshness": {
            "authority": "local bead ledger",
            "observed_at": now.isoformat().replace("+00:00", "Z"),
            "source_updated_at": changed.isoformat().replace("+00:00", "Z"),
        },
        "output_schema": schema or None,
        "authoritative_output": authoritative_pointer(rig, bead, schema),
        "retrieval": retrieval_paths(rig, bead, children),
        "active_workflow_children": [child.get("id") for child in active_children],
        "local_artifact": artifact,
        "github": github,
    }
    decision = build_decision(item, children)
    item["decision"] = decision
    archived_plans = evaluate_archive(metadata_json(bead, "gc.human_plan_archive_json"), item)
    item["archived_human_plans"] = archived_plans
    human_plan = evaluate_plan(metadata_json(bead, "gc.human_plan_json"), item)
    item["human_plan"] = human_plan
    upstream_finished = bool(github and github.get("available") and github.get("kind") == "pull_request" and
                             github.get("state") in {"CLOSED", "MERGED"})
    if upstream_finished and status != "closed":
        command = f"gc dev-pack reconcile {rig}/{bead.get('id')}"
        item["upstream_completion"] = {"state": github.get("state"), "url": github.get("url"),
                                       "reconcile_command": command}
        item["group"] = "needs-you"
        item["reason"] = f"GitHub reports the PR {str(github.get('state')).lower()} while the source remains open"
        item["next_action"] = f"record the observed upstream completion with: {command}"
    elif human_plan and status != "closed":
        state = human_plan["state"]
        wait_for = human_plan.get("wait_for")
        action = plan_action_label(str(human_plan.get("then") or ""))
        short = str(human_plan.get("head_sha") or "")[:8]
        if state == "waiting":
            item["group"] = "waiting"
            if wait_for == "ci":
                item["reason"] = f"the explicit human plan is waiting for CI on exact head {short}"
                item["next_action"] = f"when CI completes, {action.lower()} if appropriate"
            else:
                item["reason"] = f"the explicit human plan is waiting for an author update after head {short}"
                item["next_action"] = f"when the head changes, {action.lower()}"
        elif state == "ready":
            item["group"] = "needs-you"
            item["reason"] = ("CI is passing for the exact head pinned by the human plan" if wait_for == "ci"
                              else "GitHub has a new author head after the one pinned by the human plan")
            item["next_action"] = f"{action} for the current exact head"
        elif state == "ci-failing":
            item["group"] = "needs-you"
            item["reason"] = f"CI is failing on exact head {short}"
            item["next_action"] = "inspect CI failures before taking the planned action"
        elif state == "head-drift":
            item["group"] = "needs-you"
            item["reason"] = "the current GitHub head differs from the exact head pinned by the human plan"
            item["next_action"] = "re-evaluate and replace or clear the saved plan"
        else:
            item["group"] = "needs-you"
            item["reason"] = "the explicit human plan cannot currently be evaluated"
            item["next_action"] = "refresh GitHub evidence, then replace or clear the saved plan"
    elif decision and status != "closed" and (github or {}).get("state") not in {"CLOSED", "MERGED"}:
        state = decision["state"]
        if state == "upstream-action-required":
            group = item["group"] = "needs-you"
            item["reason"] = (f"the automated verdict recommends {decision['action_label'].lower()} "
                              "and GitHub has not recorded that review on the exact reviewed head")
            item["next_action"] = (f"{decision['action_label']} on GitHub for reviewed head "
                                   f"{decision['reviewed_head_sha'][:8]}, then reconcile")
        elif state == "upstream-observed":
            item["group"] = "needs-you"
            item["reason"] = (f"GitHub now reports {decision['github_review_state']} on the exact reviewed head; "
                              "the source bead has not been reconciled")
            item["next_action"] = "run the displayed reconcile command to record the upstream action"
    return item


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="gc dev-pack work",
        description="Read-only projection of current human-facing work from canonical local evidence.",
        epilog=("Selection uses ownership/assignment to --actor identities or the human-facing, "
                "attention, attention=true, or maintainer labels. --watch is explicitly deferred "
                "until the event-driven projection contract is available."),
    )
    p.add_argument("subcommand", nargs="?", choices=("show", "audit"))
    p.add_argument("target", nargs="?", help="bead id or external_ref for 'show'")
    p.add_argument("--rig", action="append", default=[], help="restrict to a rig (repeatable; use hq for city root)")
    p.add_argument("--citywide", action="store_true", help="aggregate HQ and every initialized rig")
    p.add_argument("--actor", action="append", default=[], help="human owner/assignee identity (repeatable or comma-separated)")
    p.add_argument("--group", action="append", default=[], choices=sorted(GROUP_KEYS), help="show only this group")
    p.add_argument("--limit", type=int, default=5, help="maximum rows per group (default 5)")
    p.add_argument("--all", action="store_true", help="show every row in selected groups")
    p.add_argument("--finished-within", type=duration, default=dt.timedelta(days=14), metavar="DURATION")
    p.add_argument("--json", action="store_true", help="emit stable dev-pack-work.v1 JSON")
    p.add_argument("--verbose", action="store_true", help="include deeper workflow evidence and qualifying internals")
    network = p.add_mutually_exclusive_group()
    network.add_argument("--refresh", action="store_true", help="force bounded live read-only GitHub refresh")
    network.add_argument("--no-network", action="store_true", help="use bead/local evidence and any disposable cache only")
    p.add_argument("--watch", action="store_true", help="reserved; explicitly deferred in the local MVP")
    return p


def actor_identities(values: list[str], city: str) -> set[str]:
    raw = list(values)
    raw.extend(filter(None, (os.environ.get("GC_ATTENTION_ACTORS", ""), os.environ.get("BEADS_ACTOR", ""))))
    for key in ("user.email", "user.name"):
        result = subprocess.run(["git", "-C", city, "config", key], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if result.returncode == 0 and result.stdout.strip():
            raw.append(result.stdout.strip())
    return {piece.strip().casefold() for value in raw for piece in value.split(",") if piece.strip()}


def resolve_scopes(gc: str, city: str, args: argparse.Namespace) -> tuple[str, list[dict[str, Any]]]:
    manifest = run_json([gc, "--city", city, "rig", "list", "--json"])
    rigs = [rig for rig in manifest.get("rigs", []) if rig.get("beads") == "initialized"]
    by_name = {rig["name"]: rig for rig in rigs}
    hq = next((rig for rig in rigs if rig.get("hq")), None)
    explicit = [part for value in args.rig for part in value.split(",") if part]
    if args.citywide and explicit:
        raise RuntimeError("--citywide and --rig are mutually exclusive")
    if args.citywide:
        return "citywide", rigs
    if explicit:
        selected = []
        for name in explicit:
            rig = hq if name in {"hq", "city"} else by_name.get(name)
            if not rig:
                raise RuntimeError(f"unknown rig {name!r}")
            selected.append(rig)
        return "rig" if len(selected) == 1 else "selected-rigs", selected
    env_rig = os.environ.get("GC_RIG", "")
    if env_rig and env_rig in by_name:
        return "rig", [by_name[env_rig]]
    cwd = Path.cwd().resolve()
    for rig in rigs:
        if rig.get("hq"):
            continue
        path = Path(rig["path"]).resolve()
        if cwd == path or path in cwd.parents:
            return "rig", [rig]
    return "citywide", rigs


def collect(gc: str, city: str, scopes: list[dict[str, Any]], target: str | None = None) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    collected: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for rig in scopes:
        prefix = [gc, "--city", city]
        if not rig.get("hq"):
            prefix += ["--rig", rig["name"]]
        base = prefix + ["bd", "--readonly", "list", "--all", "--limit", "0", "--json", "--flat"]
        regular = run_json(base)
        convoys = run_json(base + ["--include-infra", "--type", "convoy"])
        outputs = run_json(base + ["--include-infra", "--include-gates", "--has-metadata-key", "gc.output_json"])
        messages = run_json(base + ["--include-infra", "--type", "message"])
        unique = {bead.get("id"): bead for bead in [*regular, *convoys, *outputs, *messages] if bead.get("id")}
        if target:
            try:
                shown = run_json(prefix + ["bd", "--readonly", "show", target, "--json"])
            except RuntimeError:
                shown = []
            for bead in shown:
                if bead.get("id"):
                    unique[bead["id"]] = bead
        collected.extend((rig, bead) for bead in unique.values())
    return collected


def render_text(groups: list[dict[str, Any]], scope: dict[str, Any]) -> None:
    print(f"work · {scope['mode']} · {', '.join(scope['rigs'])}")
    any_rows = False
    for group in groups:
        print(f"\n{group['label']} ({group['total']})")
        if not group["items"]:
            print("  —")
            continue
        any_rows = True
        for item in group["items"]:
            assignee = f" · @{item['assignee']}" if item.get("assignee") else ""
            print(f"  {item['rig']}/{item['id']} · P{item['priority']} · {item['age']}{assignee}")
            print(f"    {item['title']}")
            print(f"    why: {item['reason']}")
            print(f"    next: {item['next_action']}")
            print(f"    source: {item['authoritative_output']}")
        if group["shown"] < group["total"]:
            print(f"  … {group['total'] - group['shown']} more (use --all or raise --limit)")
    if not any_rows:
        print("\nNo human-facing work matched the selection contract.")


def render_known_output(output: dict[str, Any], schema: str) -> str | None:
    if not schema.startswith("pr-review"):
        return None
    renderer = Path(__file__).resolve().parents[2] / "assets" / "scripts" / "render-verdict.sh"
    result = subprocess.run(
        [str(renderer), "-", "--brief"], input=json.dumps(output), text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    return result.stdout.rstrip() if result.returncode == 0 else None


def render_decision(decision: dict[str, Any]) -> None:
    state = decision["state"]
    sha = decision.get("reviewed_head_sha")
    if state == "upstream-action-required":
        print("\nNEXT UPSTREAM ACTION")
        print(f"{decision['action_label']} on GitHub for reviewed head {sha[:8]}:")
        print(decision.get("github_url") or "(GitHub URL unavailable)")
        print(f"\nAutomated verdict: {decision['verdict']}")
        if decision.get("summary"):
            print(decision["summary"])
        if decision.get("findings"):
            print(f"Findings: {len(decision['findings'])} (inspect the full review or render GitHub-ready text below)")
        print(f"\nFull automated review:\n{decision['commands']['full_review']}")
        print(f"\nGitHub-ready review text:\n{decision['commands']['render_feedback']}")
        print(f"\nAFTER SUBMITTING\n{decision['commands']['reconcile_after_github']}")
        print(f"\nIf you disagree and want to {decision['disagree_action_label'].lower()} instead:")
        print(decision["commands"]["disagree_render"])
        print(decision["commands"]["disagree_reconcile"])
    elif state == "upstream-observed":
        print("\nUPSTREAM ACTION OBSERVED")
        print(f"GitHub reports {decision['github_review_state']} for reviewed head {sha[:8]}.")
        print(f"Record it internally:\n{decision['commands']['reconcile_after_github']}")
    elif state == "head-drift":
        print("\nREVIEW REQUIRED")
        print(f"GitHub head {str(decision.get('current_head_sha') or 'unknown')[:8]} no longer matches reviewed head {str(sha)[:8]}.")
        print("Review the current head before taking an upstream action.")
    elif state == "review-required":
        print("\nREVIEW REQUIRED")
        print("The durable review does not record an exact reviewed SHA; repeat the review before acting upstream.")
    elif state == "github-unavailable":
        print("\nGITHUB OBSERVATION UNAVAILABLE")
        print("Refresh GitHub evidence before taking or reconciling an upstream action.")


def render_human_plan(plan: dict[str, Any], decision: dict[str, Any] | None) -> None:
    wait_for = str(plan.get("wait_for") or "")
    action = plan_action_label(str(plan.get("then") or ""))
    planned = str(plan.get("head_sha") or "unknown")
    current = str(plan.get("current_head_sha") or "unknown")
    print("\nHUMAN PLAN")
    print(f"Pinned GitHub head: {planned}")
    print(f"Plan: wait for {wait_for}, then {action.lower()}.")
    if plan.get("note"):
        print(f"Context: {plan['note']}")
    if wait_for == "ci":
        print(f"Current CI: {plan.get('ci_state') or 'unknown'}")
    state = plan.get("state")
    if state == "waiting":
        print("\nWAITING")
        print("No human action is required until the recorded condition changes.")
    elif state == "ready":
        print("\nNEXT HUMAN ACTION")
        if wait_for == "author":
            print(f"{action} the new GitHub head {current[:8]}.")
        else:
            print(f"{action} on GitHub for exact head {planned[:8]}:")
            print(plan.get("github_url") or "(GitHub URL unavailable)")
            reconcile = (plan.get("commands") or {}).get("reconcile_after_github")
            if reconcile:
                print(f"\nAFTER SUBMITTING\n{reconcile}")
    elif state == "ci-failing":
        print("\nCI NEEDS INSPECTION")
        print("Inspect the failing checks before taking the planned action.")
    elif state == "head-drift":
        print("\nPLAN NEEDS REVISION")
        print(f"Current GitHub head {current[:8]} differs from planned head {planned[:8]}.")
    else:
        print("\nPLAN NEEDS ATTENTION")
        print("The plan cannot be evaluated from the current GitHub observation.")
    if decision and (decision.get("commands") or {}).get("full_review"):
        print(f"\nPrior full automated review:\n{decision['commands']['full_review']}")
    print("\nCancel plan (does not record an upstream outcome):")
    print(plan['commands']['cancel'])
    print(f"\nReplace plan:\n{plan['commands']['replace']}")


def render_upstream_completion(completion: dict[str, Any]) -> None:
    print("\nUPSTREAM COMPLETION OBSERVED")
    print(f"GitHub reports this pull request {str(completion.get('state') or 'closed').lower()}.")
    if completion.get("url"):
        print(completion["url"])
    print("\nRecord the upstream outcome locally:")
    print(completion["reconcile_command"])


def main() -> int:
    args = parser().parse_args()
    if args.watch:
        print("work: --watch is explicitly deferred until an event-driven read-only refresh contract exists; rerun the command to refresh", file=sys.stderr)
        return 2
    if args.limit < 0:
        print("work: --limit must be non-negative", file=sys.stderr)
        return 2
    if args.subcommand == "show" and not args.target:
        print("work: show requires <bead|external-ref>", file=sys.stderr)
        return 2
    if args.target and args.subcommand != "show":
        print("work: unexpected target without 'show'", file=sys.stderr)
        return 2

    gc = os.environ.get("GC_BIN", "gc")
    city = os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY") or str(Path.cwd())
    now = parse_time(os.environ.get("DEV_PACK_WORK_NOW")) or dt.datetime.now(dt.timezone.utc)
    try:
        mode, scopes = resolve_scopes(gc, city, args)
        actors = actor_identities(args.actor, city)
        records = collect(gc, city, scopes, args.target if args.subcommand == "show" else None)
    except RuntimeError as exc:
        print(f"work: {exc}", file=sys.stderr)
        return 2

    all_by_rig: dict[str, list[dict[str, Any]]] = {}
    for rig, bead in records:
        name = "hq" if rig.get("hq") else rig["name"]
        all_by_rig.setdefault(name, []).append(bead)

    github_by_source: dict[tuple[str, str], dict[str, Any]] = {}
    query_budget = bounded_env("DEV_PACK_WORK_GITHUB_BUDGET", GITHUB_QUERY_LIMIT, GITHUB_QUERY_LIMIT)
    github_sources = []
    for rig, bead in records:
        name = "hq" if rig.get("hq") else rig["name"]
        external = str(bead.get("external_ref") or "")
        if args.subcommand == "show" and bead.get("id") != args.target and external != args.target:
            continue
        if external.startswith("gh-") and is_marked(bead) and not is_internal(bead):
            github_sources.append((rig, bead, name, external))
    for index, (rig, bead, name, external) in enumerate(github_sources):
        if index >= query_budget and not args.no_network:
            github_by_source[(name, str(bead["id"]))] = {
                "authority": "GitHub", "available": False, "freshness": "budget-exhausted",
                "observed_at": None, "error": f"per-invocation GitHub query budget is {query_budget}",
            }
        else:
            github_by_source[(name, str(bead["id"]))] = github_observation(
                city, name, rig["path"], external, now, args.refresh, args.no_network)

    if args.subcommand == "audit":
        findings: list[dict[str, Any]] = []
        checked_outputs = 0
        checked_mail = 0
        global_sources: dict[tuple[str, str], list[dict[str, Any]]] = {}
        for source_rig, source_beads in all_by_rig.items():
            for source in source_beads:
                external = str(source.get("external_ref") or "")
                if external.startswith("gh-") and is_marked(source) and not is_internal(source):
                    global_sources.setdefault((source_rig, external), []).append(source)
        reported: set[tuple[str, str, str]] = set()
        for name, beads in all_by_rig.items():
            sources: dict[str, list[dict[str, Any]]] = {}
            for bead in beads:
                external = str(bead.get("external_ref") or "")
                if external.startswith("gh-") and is_marked(bead) and not is_internal(bead):
                    sources.setdefault(external, []).append(bead)
            for external, matches in sources.items():
                if len(matches) != 1:
                    findings.append({"rig": name, "external_ref": external, "kind": "duplicate-human-source",
                                     "beads": [item.get("id") for item in matches]})
            for bead in beads:
                output = metadata_json(bead, "gc.output_json")
                schema = output_schema(bead, output)
                if schema.startswith("pr-review") and output:
                    head = str(output.get("head_ref") or "")
                    match = re.search(r"(?:#|^)([0-9]+)$", head)
                    if not match:
                        continue
                    checked_outputs += 1
                    external = f"gh-{match.group(1)}"
                    linked = str(bead.get("metadata", {}).get("gc.human_source_bead") or "")
                    candidates = sources.get(external, [])
                    key = (name, external, "durable-output-omission")
                    if key not in reported and (len(candidates) != 1 or (linked and linked != candidates[0].get("id"))):
                        reported.add(key)
                        findings.append({"rig": name, "external_ref": external, "kind": "durable-output-omission",
                                         "output_bead": bead.get("id"), "linked_source": linked or None,
                                         "candidate_sources": [item.get("id") for item in candidates]})
                if bead.get("issue_type") == "message":
                    title = str(bead.get("title") or "")
                    sender = str(bead.get("metadata", {}).get("mail.from_display") or bead.get("sender") or "")
                    if "/pr-review" not in sender and not title.lower().startswith("pr review"):
                        continue
                    target = re.match(r"^PR review\s+#?([0-9]+)(?![0-9A-Za-z])", title, re.I)
                    refs = {target.group(1)} if target else set()
                    mail_rig = sender.split("/", 1)[0] if name == "hq" and "/" in sender else name
                    for number in refs:
                        checked_mail += 1
                        external = f"gh-{number}"
                        candidates = global_sources.get((mail_rig, external), [])
                        key = (mail_rig, external, "human-mail-omission")
                        if key not in reported and len(candidates) != 1:
                            reported.add(key)
                            findings.append({"rig": mail_rig, "external_ref": external, "kind": "human-mail-omission",
                                             "mail_bead": bead.get("id"),
                                             "candidate_sources": [item.get("id") for item in candidates]})
        if args.refresh:
            for (name, source_id), observation in github_by_source.items():
                if not observation.get("available") or observation.get("freshness") != "live":
                    findings.append({"rig": name, "source_bead": source_id,
                                     "kind": "github-observation-unavailable",
                                     "freshness": observation.get("freshness"),
                                     "error": observation.get("error") or observation.get("refresh_error")})
        result = {
            "schema_version": "dev-pack-work-audit.v1",
            "generated_at": now.isoformat().replace("+00:00", "Z"),
            "scope": {"mode": mode, "rigs": list(all_by_rig)},
            "read_only": True,
            "network_mode": "no-network" if args.no_network else "refresh" if args.refresh else "cached",
            "checked": {"durable_review_outputs": checked_outputs, "human_mail_refs": checked_mail,
                        "human_sources": len(github_by_source), "github_observations": len(github_by_source)},
            "outstanding_omissions": len(findings), "findings": findings,
        }
        if args.json:
            json.dump(result, sys.stdout, indent=2, sort_keys=True); print()
        else:
            print(f"work audit · {mode} · omissions={len(findings)}")
            for finding in findings:
                print(f"  {finding['rig']}/{finding['external_ref']} · {finding['kind']}")
        return 0 if not findings else 1

    selected: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for rig, bead in records:
        marked = is_marked(bead)
        exact_show = args.subcommand == "show" and (
            bead.get("id") == args.target or bead.get("external_ref") == args.target)
        if not exact_show and not marked and not is_human_owned(bead, actors):
            continue
        if not exact_show and is_internal(bead) and not (args.verbose and marked):
            continue
        selected.append((rig, bead))

    items: list[dict[str, Any]] = []
    evidence_by_id: dict[str, dict[str, Any]] = {}
    for rig, bead in selected:
        name = "hq" if rig.get("hq") else rig["name"]
        children = workflow_children(bead, all_by_rig[name])
        item = classify(bead, children, now, name, rig["path"], github_by_source.get((name, str(bead["id"]))))
        if not item:
            continue
        if (args.subcommand != "show" and item["group"] == "recently-finished" and
                dt.timedelta(seconds=item["age_seconds"]) > args.finished_within):
            continue
        items.append(item)
        evidence_by_id[str(bead["id"])] = {
            "bead": bead,
            "output": metadata_json(bead, "gc.output_json"),
            "lifecycle": metadata_json(bead, "gc.lifecycle_json"),
            "workflow_children": children,
            "local_artifact": item.get("local_artifact"),
        }

    if args.subcommand == "show":
        matches = [item for item in items if item["id"] == args.target or item.get("external_ref") == args.target]
        if len(matches) != 1:
            message = "not found" if not matches else "ambiguous; pass --rig"
            print(f"work: {args.target!r} {message} in selected scope", file=sys.stderr)
            return 2
        item = matches[0]
        result = {
            "schema_version": "dev-pack-work-show.v1",
            "generated_at": now.isoformat().replace("+00:00", "Z"),
            "item": item,
            "evidence": evidence_by_id[item["id"]],
        }
        if args.json:
            json.dump(result, sys.stdout, indent=2, sort_keys=True)
            print()
        else:
            print(f"{item['rig']}/{item['id']} · {item['group']} · {item['status']}")
            print(item["title"])
            if item.get("upstream_completion"):
                render_upstream_completion(item["upstream_completion"])
            elif item.get("status") == "closed":
                pass
            elif item.get("human_plan"):
                render_human_plan(item["human_plan"], item.get("decision"))
            elif item.get("decision"):
                render_decision(item["decision"])
            print(f"\nwhy: {item['reason']}\nnext: {item['next_action']}\nsource: {item['authoritative_output']}")
            evidence = result["evidence"]
            if evidence.get("output"):
                print("\ndurable output:")
                rendered = render_known_output(evidence["output"], item.get("output_schema") or "")
                print(rendered or json.dumps(evidence["output"], indent=2, sort_keys=True))
            if evidence.get("lifecycle"):
                print("\nlifecycle:")
                print(json.dumps(evidence["lifecycle"], indent=2, sort_keys=True))
        return 0

    requested = set(args.group) or GROUP_KEYS
    grouped: list[dict[str, Any]] = []
    for key, label in GROUPS:
        if key not in requested:
            continue
        members = [item for item in items if item["group"] == key]
        members.sort(key=lambda item: (
            item.get("priority") if item.get("priority") is not None else 99,
            -item["age_seconds"] if key in {"needs-you", "waiting", "stale-unclear"} else item["age_seconds"],
            item["rig"], item["id"],
        ))
        visible = members if args.all else members[:args.limit]
        grouped.append({"key": key, "label": label, "total": len(members), "shown": len(visible), "items": visible})

    scope_result = {"mode": mode, "rigs": ["hq" if rig.get("hq") else rig["name"] for rig in scopes]}
    result = {
        "schema_version": "dev-pack-work.v1",
        "generated_at": now.isoformat().replace("+00:00", "Z"),
        "scope": scope_result,
        "selection": {"actors": sorted(actors), "attention_labels": sorted(ATTENTION_LABELS)},
        "network_mode": "no-network" if args.no_network else "refresh" if args.refresh else "cached",
        "cache": {"schema_version": CACHE_SCHEMA, "ttl_seconds": bounded_env("DEV_PACK_WORK_CACHE_TTL", DEFAULT_CACHE_TTL, 86400),
                  "maximum_entries": CACHE_LIMIT, "disposable": True,
                  "github_query_budget": query_budget,
                  "github_timeout_seconds": bounded_env("DEV_PACK_WORK_GITHUB_TIMEOUT", 20, 60)},
        "groups": grouped,
    }
    if args.verbose:
        result["evidence"] = evidence_by_id
    if args.json:
        json.dump(result, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        render_text(grouped, scope_result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
