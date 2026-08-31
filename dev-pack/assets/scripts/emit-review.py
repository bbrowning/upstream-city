#!/usr/bin/env python3
"""Schema-aware, stdin-first atomic output entrypoint for every review role."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


SCHEMAS = {
    "pr-triage.v1": {
        "required": {
            "schema", "posture", "ceiling_posture", "rationale", "allowed_actions",
            "facts", "base_ref", "head_ref", "failure_class", "failure_reason",
        },
        "enums": {
            "posture": {"trusted", "limited", "restricted", "block"},
            "ceiling_posture": {"trusted", "limited", "restricted", "block"},
        },
    },
    "pr-review.v1": {
        "required": {
            "schema", "head_ref", "base_ref", "implementation_provenance", "verdict",
            "posture", "effective_posture", "ceiling_posture", "summary",
            "merge_recommendation", "findings_count", "findings", "dynamic_check",
            "dynamic_request", "evidence", "read_only_enforcement", "failure_class",
            "failure_reason",
        },
        "enums": {"verdict": {"approve", "approve_with_nits", "request_changes", "blocked"}},
    },
    "pr-review-quorum.v1": {
        "required": {
            "schema", "head_ref", "base_ref", "implementation_provenance", "verdict",
            "posture", "effective_posture", "ceiling_posture", "summary",
            "merge_recommendation", "findings_count", "findings", "lanes", "evidence",
            "read_only_enforcement", "failure_class", "failure_reason",
            "has_disputed_major", "crux_question",
        },
        "enums": {"verdict": {"approve", "approve_with_nits", "request_changes", "blocked"}},
    },
    "pr-review-settle.v1": {
        "required": {
            "schema", "head_ref", "base_ref", "settle_of", "lane_beads",
            "implementation_provenance", "posture", "effective_posture", "ceiling_posture",
            "disputes_examined", "resolutions", "settled_verdict", "summary",
            "read_only_enforcement", "failure_class", "failure_reason",
        },
        "enums": {"settled_verdict": {"approve", "approve_with_nits", "request_changes", "blocked"}},
    },
    "pr-review-dynamic.v1": {
        "required": {
            "schema", "head_ref", "base_ref", "outcome", "failure_class", "failure_reason",
        },
        "enums": {},
    },
}


def die(message: str) -> None:
    print(f"emit-review: {message}", file=sys.stderr)
    raise SystemExit(2)


def validate(value: object, schema: str) -> dict:
    if not isinstance(value, dict):
        die("input must be one JSON object")
    if value.get("schema") != schema:
        die(f"input schema must be {schema!r}, got {value.get('schema')!r}")
    contract = SCHEMAS[schema]
    missing = sorted(contract["required"] - value.keys())
    if missing:
        die(f"{schema} missing required fields: {', '.join(missing)}")
    for field, allowed in contract["enums"].items():
        if value[field] not in allowed:
            die(f"{schema}.{field} must be one of {', '.join(sorted(allowed))}")
    if "findings" in value:
        if not isinstance(value["findings"], list) or type(value.get("findings_count")) is not int:
            die(f"{schema} findings must be an array and findings_count an integer")
        if len(value["findings"]) != value["findings_count"]:
            die(f"{schema} findings_count does not match findings length")
    if schema == "pr-review-quorum.v1":
        if type(value["has_disputed_major"]) is not bool or not isinstance(value["crux_question"], str):
            die("pr-review-quorum.v1 dispute markers must be boolean/string")
        disputed_major = any(
            item.get("disputed") is True and item.get("severity") in {"blocker", "major", "critical"}
            for item in value["findings"]
        )
        if value["has_disputed_major"] != disputed_major:
            die("pr-review-quorum.v1 has_disputed_major does not match disputed major/critical findings")
        if disputed_major and not value["crux_question"].strip():
            die("pr-review-quorum.v1 disputed major/critical finding requires crux_question")
    if schema == "pr-review-settle.v1":
        if not isinstance(value["resolutions"], list) or type(value["disputes_examined"]) is not int:
            die("pr-review-settle.v1 resolutions must be an array and disputes_examined an integer")
        if len(value["resolutions"]) != value["disputes_examined"]:
            die("pr-review-settle.v1 disputes_examined does not match resolutions length")
        allowed = {"resolved", "refuted", "needs_dynamic", "genuinely_ambiguous"}
        invalid = [item.get("resolution") for item in value["resolutions"] if item.get("resolution") not in allowed]
        if invalid:
            die(f"pr-review-settle.v1 has invalid resolution values: {invalid}")
    if not isinstance(value["failure_class"], str) or not isinstance(value["failure_reason"], str):
        die(f"{schema} failure fields must be strings")
    if value["failure_class"] not in {"none", "transient", "hard"}:
        die(f"{schema}.failure_class must be one of hard, none, transient")
    return value


def resolve_retry_attempt(bead_id: str) -> str:
    """Resolve a retry logical bead to its current executable attempt.

    Formula v2 retry controls own logical-step completion. Agents must close the
    attempt bead; the controller then validates and mirrors it onto the logical
    bead. Some assignment paths expose the logical id, whose blocking edge points
    at the active attempt. Closing that id directly deadlocks on its own open
    prerequisite, so redirect it before writing any result metadata.
    """
    gc = os.environ.get("GC_BIN", "gc")
    completed = subprocess.run(
        [gc, "bd", "show", bead_id, "--json"],
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        die(f"could not inspect bead {bead_id!r}: {completed.stderr.strip()}")
    try:
        value = json.loads(completed.stdout)
        bead = value[0] if isinstance(value, list) else value
    except (json.JSONDecodeError, IndexError, TypeError) as exc:
        die(f"could not parse bead {bead_id!r}: {exc}")
    if not isinstance(bead, dict):
        die(f"bead {bead_id!r} did not resolve to an object")
    metadata = bead.get("metadata") or {}
    if metadata.get("gc.kind") != "retry":
        return bead_id

    candidates = []
    for dependency in bead.get("dependencies") or []:
        dep_metadata = dependency.get("metadata") or {}
        if (
            dependency.get("status") != "closed"
            and dependency.get("dependency_type") == "blocks"
            and dep_metadata.get("gc.logical_bead_id") == bead_id
        ):
            try:
                attempt = int(dep_metadata.get("gc.attempt", ""))
            except (TypeError, ValueError):
                continue
            candidates.append((attempt, dependency.get("id", "")))
    candidates = [(attempt, dep_id) for attempt, dep_id in candidates if dep_id]
    if not candidates:
        die(f"logical retry bead {bead_id!r} has no open blocking attempt")
    highest = max(attempt for attempt, _ in candidates)
    active = sorted(dep_id for attempt, dep_id in candidates if attempt == highest)
    if len(active) != 1:
        die(f"logical retry bead {bead_id!r} has ambiguous attempt {highest}: {active}")
    print(
        f"emit-review: logical retry bead {bead_id} redirects to active attempt {active[0]}",
        file=sys.stderr,
    )
    return active[0]


def validate_trigger(bead_id: str) -> None:
    """Bind a managed pool emission to its exact immutable launch trigger."""
    trigger = os.environ.get("GC_TRIGGER_BEAD_ID", "").strip()
    if not trigger:
        if os.environ.get("GC_SESSION_ORIGIN") == "ephemeral":
            die("GC_TRIGGER_BEAD_ID is required in pooled sessions")
        return
    if trigger != bead_id:
        die(f"--bead {bead_id!r} does not match GC_TRIGGER_BEAD_ID {trigger!r}")
    gc = os.environ.get("GC_BIN", "gc")
    completed = subprocess.run(
        [gc, "bd", "show", trigger, "--json"], text=True, capture_output=True,
    )
    if completed.returncode != 0:
        die(f"could not inspect trigger bead {trigger!r}: {completed.stderr.strip()}")
    try:
        value = json.loads(completed.stdout)
        bead = value[0] if isinstance(value, list) else value
    except (json.JSONDecodeError, IndexError, TypeError) as exc:
        die(f"could not parse trigger bead {trigger!r}: {exc}")
    if not isinstance(bead, dict) or bead.get("id") != trigger:
        die(f"trigger lookup did not resolve exact bead id {trigger!r}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bead", required=True)
    parser.add_argument("--schema", choices=sorted(SCHEMAS), required=True)
    parser.add_argument("--input", default="-", help="JSON file, or - for stdin (default)")
    parser.add_argument("--outcome", choices=("pass", "fail"), default="pass")
    parser.add_argument("--failure-class", choices=("none", "transient", "hard"), default="none")
    parser.add_argument("--failure-reason", default="")
    parser.add_argument("--reason", default="")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--implementation-artifact-ref", default="")
    parser.add_argument("--implementation-artifact-id", default=None)
    parser.add_argument("--implementation-repository-id", default="")
    parser.add_argument("--implementation-branch", default="")
    parser.add_argument("--implementation-revision", default="")
    parser.add_argument("--implementation-base-sha", default="")
    parser.add_argument("--implementation-head-sha", default="")
    parser.add_argument("--auto-settle", action="store_true")
    parser.add_argument("--settle-target", default="")
    parser.add_argument("--resynth-target", default="")
    args = parser.parse_args()
    if args.auto_settle and args.schema != "pr-review-quorum.v1":
        die("--auto-settle is only valid for pr-review-quorum.v1")

    try:
        raw = sys.stdin.read() if args.input == "-" else Path(args.input).read_text()
        payload = json.loads(raw)
    except (OSError, json.JSONDecodeError) as exc:
        die(f"invalid or unreadable JSON input: {exc}")
    payload = validate(payload, args.schema)
    if payload["failure_class"] != args.failure_class:
        die("JSON failure_class does not match --failure-class")
    if payload["failure_reason"] != args.failure_reason:
        die("JSON failure_reason does not match --failure-reason")

    # This check is deliberately before retry resolution and before either child
    # emitter can write failure provenance.
    validate_trigger(args.bead)
    target_bead = resolve_retry_attempt(args.bead)

    script_dir = Path(__file__).resolve().parent
    triage = args.schema == "pr-triage.v1"
    emitter = script_dir / ("emit-json.sh" if triage else "emit-verdict.sh")
    command = [
        str(emitter), "--bead", target_bead,
        "--json-file" if triage else "--verdict-file", "PLACEHOLDER",
        "--outcome", args.outcome,
    ]
    if triage:
        command.extend(["--schema", args.schema])
    else:
        command.extend(["--repo", args.repo])
        if args.implementation_artifact_id is not None:
            command.extend([
                "--implementation-artifact-ref", args.implementation_artifact_ref,
                "--implementation-artifact-id", args.implementation_artifact_id,
                "--implementation-repository-id", args.implementation_repository_id,
                "--implementation-branch", args.implementation_branch,
                "--implementation-revision", args.implementation_revision,
                "--implementation-base-sha", args.implementation_base_sha,
                "--implementation-head-sha", args.implementation_head_sha,
            ])
    if args.failure_class != "none":
        command.extend(["--failure-class", args.failure_class, "--failure-reason", args.failure_reason])
    if args.reason:
        command.extend(["--reason", args.reason])

    # The caller never creates or cleans a temp file. The named file exists only for
    # the duration of the child emitter and is removed by Python on every exit path.
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        command[command.index("PLACEHOLDER")] = handle.name
        emitter_env = os.environ.copy()
        emitter_env["DEV_PACK_VALIDATED_TRIGGER_BEAD_ID"] = args.bead
        emitter_env["DEV_PACK_VALIDATED_OUTPUT_BEAD_ID"] = target_bead
        if args.auto_settle and payload["has_disputed_major"]:
            # The initial disputed synthesis is durable but intermediate. Quality
            # auto-settle sends one human-facing verdict after final re-synthesis.
            emitter_env["GC_PR_NOTIFY_TO"] = ""
        completed = subprocess.run(command, env=emitter_env)
    result = completed.returncode
    terminal_attempt = completed.returncode == 0
    if result == 0 and args.auto_settle:
        settle = script_dir / "auto-settle-review.sh"
        settle_command = [str(settle), "--synthesis", target_bead]
        if args.settle_target:
            settle_command.extend(["--arbiter-target", args.settle_target])
        if args.resynth_target:
            settle_command.extend(["--resynth-target", args.resynth_target])
        result = subprocess.run(settle_command).returncode
        if result != 0:
            gc = os.environ.get("GC_BIN", "gc")
            subprocess.run(
                [gc, "bd", "update", target_bead, "--set-metadata", "gc.auto_settle_error=launch-failed"],
                check=False,
            )
            notify_to = os.environ.get("GC_PR_NOTIFY_TO", "human")
            if notify_to and payload["has_disputed_major"]:
                rendered = subprocess.run(
                    [str(script_dir / "render-verdict.sh"), "-", "--bead", target_bead, "--brief"],
                    input=json.dumps(payload), text=True, capture_output=True,
                )
                body = rendered.stdout if rendered.returncode == 0 else (
                    f"Automatic settlement failed to launch for {target_bead}. "
                    f"Run: gc dev-pack summary {target_bead} --full"
                )
                subprocess.run(
                    [gc, "mail", "send", notify_to,
                     "-s", f"PR review {payload['head_ref']}: settlement launch failed",
                     "-m", body],
                    check=False,
                )

    # A terminal attempt must not receive the stale trigger nudge while the
    # controller mirrors it onto the logical retry bead. A genuine retry gets a
    # fresh attempt/session from the controller.
    if terminal_attempt:
        subprocess.run([str(script_dir / "quiesce-current-session.sh")], check=False)
    raise SystemExit(result)


if __name__ == "__main__":
    main()
