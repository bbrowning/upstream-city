#!/usr/bin/env python3
"""Continue approved feature or hard-bug work from explicit human feedback."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
POLICY = ROOT / "dev-pack" / "assets" / "workflow-policy.json"
RESOLVE = Path(os.environ.get("DEV_PACK_RESOLVE_LOCAL_CHANGE") or
               ROOT / "dev-pack" / "assets" / "scripts" / "resolve-local-change.sh")


class IterateError(RuntimeError):
    pass


def run(command: list[str], *, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, input=input_text, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE)


def checked(command: list[str], message: str, *, input_text: str | None = None) -> str:
    result = run(command, input_text=input_text)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or message
        raise IterateError(detail)
    return result.stdout.strip()


def decode(value: Any) -> Any:
    if not isinstance(value, str):
        return value
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return None


def one(raw: str) -> dict[str, Any]:
    value = json.loads(raw)
    if isinstance(value, list):
        if len(value) != 1:
            raise IterateError("bead lookup did not return exactly one record")
        value = value[0]
    if not isinstance(value, dict):
        raise IterateError("bead lookup returned an invalid record")
    return value


def gc_prefix(gc: str, city: str, rig: str | None = None) -> list[str]:
    command = [gc, "--city", city]
    if rig:
        command += ["--rig", rig]
    return command


def rigs(gc: str, city: str) -> list[dict[str, Any]]:
    raw = checked(gc_prefix(gc, city) + ["rig", "list", "--json"], "could not list rigs")
    value = json.loads(raw)
    return list(value.get("rigs") or [])


def parse_target(target: str, explicit_rig: str | None, known_rigs: list[dict[str, Any]]) -> tuple[str, str]:
    if "/" in target:
        qualified, bead = target.split("/", 1)
        if not qualified or not bead:
            raise IterateError("qualified target must be RIG/BEAD")
        if explicit_rig and explicit_rig != qualified:
            raise IterateError(f"target selects rig {qualified!r}, conflicting with --rig {explicit_rig!r}")
        return bead, qualified
    if explicit_rig:
        return target, explicit_rig
    matches = [str(item["name"]) for item in known_rigs
               if target.startswith(str(item["name"]) + "-")]
    if not matches:
        raise IterateError(f"cannot infer rig from bead {target!r}; pass --rig NAME")
    return target, max(matches, key=len)


def feedback_text(args: argparse.Namespace, *, allow_stored: bool = False) -> str | None:
    if args.feedback is not None and args.file is not None:
        raise IterateError("use either inline feedback or --file, not both")
    if args.feedback is not None:
        text = args.feedback
    elif args.file is not None:
        if args.file == "-":
            text = sys.stdin.read()
        else:
            try:
                text = Path(args.file).read_text()
            except OSError as exc:
                raise IterateError(f"cannot read feedback file {args.file!r}: {exc}") from exc
    elif not sys.stdin.isatty():
        text = sys.stdin.read()
        if not text and allow_stored:
            return None
    elif allow_stored:
        return None
    else:
        editor = os.environ.get("VISUAL") or os.environ.get("EDITOR") or "vi"
        with tempfile.NamedTemporaryFile(prefix="dev-pack-feedback-", suffix=".md", delete=False) as handle:
            path = Path(handle.name)
        try:
            result = subprocess.run(shlex.split(editor) + [str(path)])
            if result.returncode:
                raise IterateError(f"editor exited with status {result.returncode}")
            text = path.read_text()
        finally:
            path.unlink(missing_ok=True)
    if not text.strip():
        raise IterateError("feedback must contain non-whitespace text")
    return text


def lifecycle_from(bead: dict[str, Any]) -> dict[str, Any]:
    lifecycle = decode((bead.get("metadata") or {}).get("gc.lifecycle_json"))
    if not isinstance(lifecycle, dict) or lifecycle.get("schema") != "work-lifecycle.v1":
        raise IterateError("work bead has no valid dev-pack lifecycle checkpoint")
    return lifecycle


def artifact_candidates(items: list[dict[str, Any]], work_bead: str,
                        lifecycle: dict[str, Any]) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    found: list[tuple[dict[str, Any], dict[str, Any]]] = []
    expected_schema = "feature-dev.v2" if lifecycle["intent_kind"] == "feature" else "hard-bug-implement.v2"
    for item in items:
        metadata = item.get("metadata") or {}
        if metadata.get("gc.output_json_schema") != expected_schema:
            continue
        output = decode(metadata.get("gc.output_json"))
        local = output.get("local_change") if isinstance(output, dict) else None
        if not isinstance(local, dict):
            continue
        producer = local.get("producer") or {}
        head = local.get("head") or {}
        revision = local.get("revision") or {}
        if (local.get("artifact_id") == lifecycle.get("artifact_id")
                and producer.get("bead") == work_bead
                and producer.get("intent_kind") == lifecycle.get("intent_kind")
                and revision.get("number") == lifecycle.get("iteration")
                and head.get("sha") == lifecycle.get("head_sha")
                and head.get("branch") == lifecycle.get("branch")):
            found.append((item, local))
    return found


def find_artifact(gc: str, city: str, rig: str, repo: str, work_bead: str,
                  lifecycle: dict[str, Any]) -> tuple[str, dict[str, Any], dict[str, Any]]:
    prefix = gc_prefix(gc, city, rig)
    preferred = lifecycle.get("artifact_ref")
    candidates: list[tuple[dict[str, Any], dict[str, Any]]] = []
    if preferred:
        shown = one(checked(prefix + ["bd", "show", str(preferred), "--json"],
                            f"artifact bead {preferred!r} is missing"))
        candidates = artifact_candidates([shown], work_bead, lifecycle)
    if not candidates:
        raw = checked(prefix + ["bd", "list", "--all", "--limit", "0", "--json"],
                      "could not search implementation artifacts")
        listed = json.loads(raw)
        candidates = artifact_candidates(listed if isinstance(listed, list) else [], work_bead, lifecycle)
    # Retry-controlled steps mirror the attempt output onto one logical bead. Treat
    # that pair as one artifact and retain the stable logical reference.
    if len(candidates) > 1:
        logical = [candidate for candidate in candidates
                   if (candidate[0].get("metadata") or {}).get("gc.kind") == "retry"]
        fingerprints = {json.dumps(candidate[1], sort_keys=True, separators=(",", ":"))
                        for candidate in candidates}
        if len(logical) == 1 and len(fingerprints) == 1:
            candidates = logical
    if len(candidates) != 1:
        raise IterateError("approved lifecycle must resolve to exactly one matching implementation artifact "
                           f"(found {len(candidates)})")
    item, local = candidates[0]
    resolved = checked([str(RESOLVE), "--repo", repo, "--rig", rig, "--artifact", str(item["id"]),
                        "--require-internal-producer"], "approved artifact validation failed")
    verified = json.loads(resolved)
    return str(item["id"]), verified, item


def installed_agents(gc: str, city: str) -> set[str]:
    raw = checked(gc_prefix(gc, city) + ["agent", "list"], "could not list installed agents")
    return {line.split()[0] for line in raw.splitlines() if line.strip()}


def iteration_record(metadata: dict[str, Any]) -> dict[str, Any] | None:
    record = decode(metadata.get("gc.human_iteration_json"))
    return record if isinstance(record, dict) and record.get("schema") == "dev-pack-human-iteration.v1" else None


def matching_workflow(items: list[dict[str, Any]], feedback_bead: str,
                      work_bead: str, revision: int) -> str | None:
    matches = []
    for item in items:
        metadata = item.get("metadata") or {}
        if (str(metadata.get("gc.var.feedback_bead") or "") == feedback_bead
                and str(metadata.get("gc.var.revision") or "") == str(revision)
                and (str(metadata.get("gc.var.work_bead") or metadata.get("gc.var.bug_bead") or "") == work_bead)):
            matches.append(str(item.get("id")))
    if len(matches) > 1:
        raise IterateError("multiple workflows already exist for this human feedback; inspect the rig ledger")
    return matches[0] if matches else None


def parse_sling_root(raw: str) -> str | None:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if isinstance(value, dict):
        for key in ("root_bead_id", "bead_id", "id", "workflow_id"):
            if value.get(key):
                return str(value[key])
        for key in ("workflow", "bead", "result"):
            nested = value.get(key)
            if isinstance(nested, dict):
                for nested_key in ("root_bead_id", "id"):
                    if nested.get(nested_key):
                        return str(nested[nested_key])
    return None


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(
        prog="gc dev-pack iterate",
        description="Continue an approved, closed feature or hard bug from explicit human feedback.",
    )
    value.add_argument("bead", help="approved feature/bug bead, optionally qualified as RIG/BEAD")
    value.add_argument("feedback", nargs="?", help="quoted human feedback; use --file for multiline input")
    value.add_argument("--rig", help="rig (default: infer from bead prefix)")
    value.add_argument("--file", metavar="PATH", help="read feedback from PATH; use - for stdin")
    value.add_argument("--max-review-iterations", type=int, metavar="N",
                       help="artifact budget for this fresh human-requested pass (default: 3)")
    value.add_argument("--dry-run", action="store_true",
                       help="validate and print the transition without mutating anything")
    return value


def main() -> int:
    args = parser().parse_args()
    gc = os.environ.get("GC_BIN", "gc")
    city = os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY") or os.getcwd()
    try:
        policy = json.loads(POLICY.read_text())
        budget = (args.max_review_iterations if args.max_review_iterations is not None
                  else int(policy["defaults"]["max_review_iterations"]))
        if budget < 1:
            raise IterateError("--max-review-iterations must be a positive integer")
        known_rigs = rigs(gc, city)
        bead_id, rig = parse_target(args.bead, args.rig, known_rigs)
        rig_data = next((item for item in known_rigs if item.get("name") == rig), None)
        if not rig_data:
            raise IterateError(f"unknown rig {rig!r}")
        repo = str(rig_data["path"])
        lock_root = Path(os.environ.get("GC_CITY_RUNTIME_DIR") or Path(city) / ".gc" / "runtime")
        lock_dir = lock_root / "dev-pack" / "iteration-locks"
        lock_dir.mkdir(parents=True, exist_ok=True)
        safe = "".join(char if char.isalnum() or char in "._-" else "_" for char in f"{rig}-{bead_id}")
        with (lock_dir / f"{safe}.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            prefix = gc_prefix(gc, city, rig)
            work = one(checked(prefix + ["bd", "show", bead_id, "--json"],
                               f"work bead {bead_id!r} was not found in rig {rig!r}"))
            metadata = work.get("metadata") or {}
            lifecycle = lifecycle_from(work)
            existing_iteration = iteration_record(metadata)
            if (existing_iteration and existing_iteration.get("state") == "launched"
                    and work.get("status") == "closed"
                    and lifecycle.get("checkpoint") == "review"
                    and lifecycle.get("disposition") == "approved"
                    and int(lifecycle.get("iteration") or 0) >= int(existing_iteration.get("revision") or 0)):
                # The retained launch receipt is history once that revision (or a
                # later automatic revision) reaches a new approved checkpoint.
                existing_iteration = None

            if existing_iteration and existing_iteration.get("state") in {"prepared", "launched"}:
                supplied = feedback_text(args, allow_stored=True)
                expected_hash = str(existing_iteration.get("feedback_sha256") or "")
                if supplied is not None and hashlib.sha256(supplied.encode()).hexdigest() != expected_hash:
                    raise IterateError("a different human iteration is already prepared or running for this work bead")
                feedback_bead = str(existing_iteration["feedback_bead"])
                revision = int(existing_iteration["revision"])
                if existing_iteration["state"] == "launched":
                    print(f"iterate: revision {revision} is already running for {rig}/{bead_id}")
                    print(f"  feedback: {feedback_bead}")
                    print(f"  workflow: {existing_iteration.get('workflow_bead') or 'launched'}")
                    return 0
                listed = json.loads(checked(prefix + ["bd", "list", "--all", "--limit", "0", "--json"],
                                            "could not inspect prepared iteration"))
                workflow = matching_workflow(listed, feedback_bead, bead_id, revision)
                if workflow:
                    existing_iteration.update(state="launched", workflow_bead=workflow)
                    checked(prefix + ["bd", "update", bead_id, "--set-metadata",
                                      "gc.human_iteration_json=" + json.dumps(existing_iteration, separators=(",", ":"))],
                            "could not record recovered workflow")
                    print(f"iterate: revision {revision} is already running for {rig}/{bead_id}")
                    print(f"  feedback: {feedback_bead}")
                    print(f"  workflow: {workflow}")
                    return 0
                feedback = supplied
                if feedback is None:
                    feedback_item = one(checked(prefix + ["bd", "show", feedback_bead, "--json"],
                                                "prepared feedback bead is missing"))
                    feedback_output = decode((feedback_item.get("metadata") or {}).get("gc.output_json"))
                    feedback = str((feedback_output or {}).get("feedback") or "")
                predecessor = existing_iteration["predecessor"]
                artifact_ref = str(predecessor["artifact_ref"])
                local = json.loads(checked([str(RESOLVE), "--repo", repo, "--rig", rig,
                                            "--artifact", artifact_ref],
                                           "prepared predecessor artifact is no longer valid"))
                intent = str(existing_iteration["intent_kind"])
                implementer = str(existing_iteration["implementer_target"])
                absolute_max = int(existing_iteration["max_iteration"])
            else:
                if work.get("status") != "closed" or lifecycle.get("checkpoint") != "review" or lifecycle.get("disposition") != "approved":
                    raise IterateError("work must be closed at an approved review checkpoint; open review changes already iterate automatically")
                intent = str(lifecycle.get("intent_kind") or "")
                if intent not in {"feature", "hard_bug"}:
                    raise IterateError("iterate supports approved feature and hard-bug work only")
                feedback = feedback_text(args)
                assert feedback is not None
                artifact_ref, local, artifact_item = find_artifact(gc, city, rig, repo, bead_id, lifecycle)
                revision = int(lifecycle["iteration"]) + 1
                absolute_max = revision + budget - 1
                implementer = str((artifact_item.get("metadata") or {}).get("gc.execution_routed_to") or "")
                if not implementer:
                    raise IterateError("approved implementation does not record its implementation target")
                profile = str(policy["defaults"]["execution_profile"])
                lane_a = f"{rig}/{policy['execution_profiles'][profile]['roles']['review']['lane_a']}"
                lane_b = f"{rig}/{policy['execution_profiles'][profile]['roles']['review']['lane_b']}"
                required_targets = [implementer, lane_a, lane_b]
                if intent == "hard_bug":
                    required_targets.append(f"{rig}/bug-coordinator")
                agents = installed_agents(gc, city)
                for target in required_targets:
                    if target not in agents:
                        raise IterateError(f"required installed target {target!r} is unavailable")
                feedback_bead = "DRY-RUN-FEEDBACK"
                feedback_hash = hashlib.sha256(feedback.encode()).hexdigest()
                predecessor = {
                    "artifact_ref": artifact_ref,
                    "artifact_id": local["artifact_id"],
                    "revision": local["revision"]["number"],
                    "head_sha": local["head"]["sha"],
                    "branch": local["head"]["branch"],
                    "base_ref": local["base"]["ref"],
                    "base_sha": local["base"]["sha"],
                    "approval_feedback_bead": lifecycle.get("feedback_bead"),
                    "approval_verdict": lifecycle.get("reason"),
                }
                if args.dry_run:
                    print(f"DRY RUN — would iterate {rig}/{bead_id}")
                    print(f"  approved: r{predecessor['revision']} {predecessor['artifact_id']} @ {predecessor['head_sha']}")
                    print(f"  starting: r{revision} (automatic review budget through r{absolute_max})")
                    print(f"  feedback sha256: {feedback_hash}")
                    print(f"  implementation target: {implementer}")
                    print("  remote mutation: false")
                    return 0
                now = __import__("datetime").datetime.now(__import__("datetime").timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
                feedback_record = {
                    "schema": "dev-pack-human-feedback.v1", "work_bead": bead_id,
                    "intent_kind": intent, "feedback": feedback, "feedback_sha256": feedback_hash,
                    "requested_revision": revision, "predecessor": predecessor, "created_at": now,
                }
                feedback_meta = {"gc.output_json_schema": "dev-pack-human-feedback.v1",
                                 "gc.output_json": json.dumps(feedback_record, separators=(",", ":"))}
                feedback_bead = checked(prefix + ["bd", "create", f"Human feedback for {bead_id} revision {revision}",
                                          "--type", "task", "--priority", "2", "--labels", "dev-pack,human-feedback",
                                          "--parent", bead_id, "--description", feedback,
                                          "--metadata", json.dumps(feedback_meta, separators=(",", ":")), "--silent"],
                                        "could not create human feedback bead")
                checked(prefix + ["bd", "close", feedback_bead, "--reason", f"human feedback captured for revision {revision}"],
                        "could not close human feedback evidence bead")
                existing_iteration = {
                    "schema": "dev-pack-human-iteration.v1", "state": "prepared", "work_bead": bead_id,
                    "intent_kind": intent, "revision": revision, "max_iteration": absolute_max,
                    "feedback_bead": feedback_bead, "feedback_sha256": feedback_hash,
                    "implementer_target": implementer,
                    "predecessor": predecessor,
                }
                checked(prefix + ["bd", "update", bead_id, "--set-metadata",
                                  "gc.human_iteration_json=" + json.dumps(existing_iteration, separators=(",", ":"))],
                        "could not prepare human iteration")
                checked(prefix + ["bd", "reopen", bead_id, "--reason", f"human feedback requested revision {revision} ({feedback_bead})"],
                        "could not reopen approved work")
                predecessor_json = json.dumps(predecessor, separators=(",", ":"))
                checked([str(ROOT / "dev-pack" / "assets" / "scripts" / "update-work-lifecycle.sh"),
                         "--city", city, "--rig", rig, "--bead", bead_id, "--intent", intent,
                         "--checkpoint", "human_feedback", "--disposition", "implementing",
                         "--iteration", str(revision), "--feedback-bead", feedback_bead,
                         "--reason", "request_changes", "--predecessor-json", predecessor_json],
                        "could not record human-feedback lifecycle transition")

            if args.dry_run:
                print(f"DRY RUN — iteration r{revision} is already prepared for {rig}/{bead_id}")
                print(f"  feedback: {feedback_bead}")
                print(f"  automatic review budget through r{absolute_max}")
                return 0

            agents = installed_agents(gc, city)
            profile = str(policy["defaults"]["execution_profile"])
            lane_a = f"{rig}/{policy['execution_profiles'][profile]['roles']['review']['lane_a']}"
            lane_b = f"{rig}/{policy['execution_profiles'][profile]['roles']['review']['lane_b']}"
            for target in (implementer, lane_a, lane_b):
                if target not in agents:
                    raise IterateError(f"required installed target {target!r} is unavailable")
            base = str(local["base"]["sha"])
            common = [implementer]
            if intent == "feature":
                common += ["feature-dev", "--formula", "--var", f"work_bead={bead_id}",
                           "--var", f"base={base}", "--var", "fetch_base=false",
                           "--var", f"implementer_target={implementer}"]
            else:
                branch = str(local["head"]["branch"])
                if not branch.endswith(bead_id):
                    raise IterateError(f"approved hard-bug branch {branch!r} does not end with work bead {bead_id!r}")
                branch_prefix = branch[:-len(bead_id)]
                coordinator = f"{rig}/bug-coordinator"
                if coordinator not in agents:
                    raise IterateError(f"required installed target {coordinator!r} is unavailable")
                common += ["hard-bug-finalize", "--formula", "--var", f"bug_bead={bead_id}",
                           "--var", f"base={base}", "--var", f"branch_prefix={branch_prefix}",
                           "--var", f"implementer_target={implementer}",
                           "--var", f"coordinator_target={coordinator}"]
            common += ["--var", f"revision={revision}", "--var", f"previous_artifact_id={local['artifact_id']}",
                       "--var", f"feedback_bead={feedback_bead}", "--var", "producing_verdict=request_changes",
                       "--var", "review_n=2", "--var", f"max_review_iterations={absolute_max}",
                       "--var", f"review_lane_a_target={lane_a}", "--var", f"review_lane_b_target={lane_b}",
                       "--title", f"human feedback revision {revision}: {bead_id}",
                       "--scope-kind", "rig", "--scope-ref", feedback_bead, "--json"]
            result = run(gc_prefix(gc, city, rig) + ["sling"] + common)
            if result.returncode:
                detail = result.stderr.strip() or result.stdout.strip() or "workflow dispatch failed"
                raise IterateError(f"iteration is prepared but dispatch failed; rerun the same command to resume: {detail}")
            workflow = parse_sling_root(result.stdout.strip()) or "launched"
            existing_iteration.update(state="launched", workflow_bead=workflow)
            checked(prefix + ["bd", "update", bead_id, "--set-metadata",
                              "gc.human_iteration_json=" + json.dumps(existing_iteration, separators=(",", ":"))],
                    "workflow launched but its receipt could not be recorded")
            print(f"iterate: launched revision {revision} for {rig}/{bead_id}")
            print(f"  approved: r{local['revision']['number']} {local['artifact_id']} @ {local['head']['sha']}")
            print(f"  feedback: {feedback_bead}")
            print(f"  review budget: through r{absolute_max}")
            print(f"  workflow: {workflow}")
            return 0
    except (IterateError, KeyError, ValueError, TypeError, json.JSONDecodeError, OSError) as exc:
        print(f"iterate: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
