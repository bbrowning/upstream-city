#!/usr/bin/env python3
"""Read-only human-attention projection for dev-pack work."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Any


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


def authoritative_pointer(rig: str, bead: dict[str, Any], schema: str) -> str:
    rig_arg = "" if rig == "hq" else f" --rig {rig}"
    if schema.startswith("pr-review"):
        return f"gc dev-pack summary {bead['id']}{rig_arg}"
    if schema == "hard-bug-state.v1":
        return f"gc dev-pack status {bead['id']}{rig_arg}"
    return f"gc{rig_arg} bd show {bead['id']}"


def classify(bead: dict[str, Any], children: list[dict[str, Any]], now: dt.datetime,
             rig: str, rig_path: str) -> dict[str, Any] | None:
    status = bead.get("status", "open")
    changed = parse_time(bead.get("closed_at") if status == "closed" else bead.get("updated_at"))
    changed = changed or parse_time(bead.get("created_at")) or now
    age_seconds = max(0, int((now - changed).total_seconds()))
    output = metadata_json(bead, "gc.output_json")
    lifecycle = metadata_json(bead, "gc.lifecycle_json")
    schema = output_schema(bead, output)
    artifact = local_artifact(lifecycle, rig_path)
    child_outputs = [child for child in children if metadata_json(child, "gc.output_json")]
    active_children = [child for child in children if child.get("status") in {"open", "in_progress", "blocked"}]

    reason: str
    next_action: str
    bead_labels = labels(bead)
    if status == "closed":
        group = "recently-finished"
        reason = "the human-facing bead itself is closed"
        next_action = "none; reopen only if the human disposition changes"
    elif bead_labels & NEEDS_LABELS:
        group = "needs-you"
        reason = f"explicit human-action marker: {sorted(bead_labels & NEEDS_LABELS)[0]}"
        next_action = "review the authoritative evidence and record a disposition"
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

    return {
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
        "active_workflow_children": [child.get("id") for child in active_children],
        "local_artifact": artifact,
    }


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="gc dev-pack work",
        description="Read-only projection of current human-facing work from canonical local evidence.",
        epilog=("Selection uses ownership/assignment to --actor identities or the human-facing, "
                "attention, attention=true, or maintainer labels. --watch is explicitly deferred "
                "until the event-driven projection contract is available."),
    )
    p.add_argument("subcommand", nargs="?", choices=("show",))
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
        unique = {bead.get("id"): bead for bead in [*regular, *convoys, *outputs] if bead.get("id")}
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
        item = classify(bead, children, now, name, rig["path"])
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
