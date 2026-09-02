#!/usr/bin/env python3
"""Validate every workflow-authored commit message in an immutable range."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


MAILBOX_RE = re.compile(r"^\s*(.*?)\s*<([^<>]+)>\s*$")
AGENT_IDENTITY_RE = re.compile(
    r"(?i)(?:\b(?:codex|chatgpt|gpt(?:-?\d+)?|claude|gemini|"
    r"copilot|language[ -]model|ai[ -](?:assistant|agent)|coding[ -]agent)\b|"
    r"\b(?:agent|bot)\b|\[[^]]*bot\]|(?:^|[+._-])bot(?:@|[+._-]|$))"
)


def git(repo: Path, *args: str, text: bool = True):
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=True, capture_output=True, text=text
    ).stdout


def fail(message: str) -> None:
    raise SystemExit(f"validate-commit-series: {message}")


def committed_text(repo: Path, head: str, relative: str) -> str | None:
    result = subprocess.run(
        ["git", "-C", str(repo), "show", f"{head}:{relative}"],
        capture_output=True,
        text=True,
    )
    return result.stdout if result.returncode == 0 else None


def policy_for(repo: Path, head: str, changed_paths: list[str]) -> dict:
    root = Path(git(repo, "rev-parse", "--show-toplevel").strip()).resolve()
    policy = {"subject_max": 72, "body_max": 100, "require_body": True, "sources": ["dev-pack defaults"]}
    candidates = {Path("AGENTS.md")}
    for changed in changed_paths:
        parent = Path(changed).parent
        while True:
            candidates.add(parent / "AGENTS.md")
            if parent == Path("."):
                break
            parent = parent.parent
    config_name = ".commit-message-policy.json"
    config_text = committed_text(repo, head, config_name)
    if config_text is not None:
        try:
            configured = json.loads(config_text)
        except json.JSONDecodeError as exc:
            fail(f"invalid {config_name} at {head}: {exc}")
        for key in ("subject_max", "body_max"):
            if key in configured:
                value = configured[key]
                if not isinstance(value, int) or value < 1:
                    fail(f"{config_name}: {key} must be a positive integer")
                policy[key] = min(policy[key], value)
        if configured.get("require_body") is True:
            policy["require_body"] = True
        policy["sources"].append(config_name)

    for agents in sorted(str(path).removeprefix("./") for path in candidates):
        text = committed_text(repo, head, agents)
        if text is None:
            continue
        found = False
        for match in re.finditer(r"(?i)(?:wrap(?:ping)?\s+(?:all\s+)?lines?\s+(?:at|to)|all\s+lines?[^0-9]{0,12})(\d+)\s*(?:characters?|chars?)", text):
            limit = int(match.group(1))
            policy["subject_max"] = min(policy["subject_max"], limit)
            policy["body_max"] = min(policy["body_max"], limit)
            found = True
        for key, label in (("subject_max", "subject"), ("body_max", "body")):
            for match in re.finditer(rf"(?i){label}.{{0,40}}?(\d+)\s*(?:characters?|chars?)", text):
                policy[key] = min(policy[key], int(match.group(1)))
                found = True
        if re.search(r"(?i)(?:what/why|nonempty|required|concise).{0,30}body|body\s+below\s+the\s+subject", text):
            policy["require_body"] = True
            found = True
        if found:
            policy["sources"].append(agents)
    return policy


def paragraphs(body_lines: list[str]) -> list[list[str]]:
    result: list[list[str]] = []
    current: list[str] = []
    for line in body_lines:
        if line == "":
            if current:
                result.append(current)
                current = []
        else:
            current.append(line)
    if current:
        result.append(current)
    return result


def configured_agent_identity(repo: Path) -> tuple[str, str] | None:
    """Return Git's configured identity only when it is recognizably non-human."""
    def config(key: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(repo), "config", "--get", key],
            capture_output=True,
            text=True,
        )
        return result.stdout.strip() if result.returncode == 0 else ""

    name, email = config("user.name"), config("user.email")
    combined = f"{name} <{email}>"
    return (name, email) if AGENT_IDENTITY_RE.search(combined) else None


def signed_off_values(raw: str) -> list[str]:
    """Parse only Git's terminal trailer block, not prose mentioning a trailer."""
    result = subprocess.run(
        ["git", "interpret-trailers", "--parse"],
        input=raw,
        capture_output=True,
        text=True,
        check=True,
    )
    values = []
    for line in result.stdout.splitlines():
        key, separator, value = line.partition(":")
        if separator and key.casefold() == "signed-off-by":
            values.append(value.strip())
    return values


def signoff_kind(value: str, agent_identity: tuple[str, str] | None) -> str:
    mailbox = MAILBOX_RE.match(value)
    name, email = mailbox.groups() if mailbox else (value, "")
    if AGENT_IDENTITY_RE.search(f"{name} <{email}>"):
        return "agent"
    if agent_identity:
        agent_name, agent_email = agent_identity
        if (
            name.casefold() == agent_name.casefold()
            and email.casefold() == agent_email.casefold()
        ):
            return "agent"
    return "human"


def validate_message(
    raw: str, policy: dict, agent_identity: tuple[str, str] | None = None
) -> tuple[dict, list[str]]:
    raw = raw.rstrip("\n")
    lines = raw.split("\n")
    subject = lines[0] if lines else ""
    separated = len(lines) > 1 and lines[1] == ""
    body_lines = lines[2:] if separated else lines[1:]
    body = "\n".join(body_lines).strip("\n")
    errors = []
    signoffs = signed_off_values(raw)
    classified_signoffs = [
        (value, signoff_kind(value, agent_identity)) for value in signoffs
    ]
    agent_signoffs = [value for value, kind in classified_signoffs if kind == "agent"]
    human_signoffs = [value for value, kind in classified_signoffs if kind == "human"]
    if not subject.strip():
        errors.append("empty-subject")
    if len(subject) > policy["subject_max"]:
        errors.append(f"subject-over-{policy['subject_max']}-characters")
    if policy["require_body"] and not body.strip():
        errors.append("empty-body")
    if body.strip() and not separated:
        errors.append("missing-subject-body-separation")
    for number, line in enumerate(body_lines, start=3):
        if len(line) > policy["body_max"]:
            errors.append(f"body-line-{number}-over-{policy['body_max']}-characters")

    if agent_signoffs:
        errors.append("agent-signed-off-by")

    body_paragraphs = paragraphs(body_lines)
    non_prose = re.compile(r"^(?:[-*+] |\d+[.)] |```|    )")
    for left, right in zip(body_paragraphs, body_paragraphs[1:]):
        if (
            len(left) == len(right) == 1
            and not non_prose.match(left[0])
            and not non_prose.match(right[0])
            and not re.search(r"[.!?:;)\]]$", left[0].rstrip())
        ):
            errors.append("malformed-fragmented-paragraph-wrapping")
            break
    evidence = {
        "subject": subject,
        "body": body,
        "subject_length": len(subject),
        "max_body_line_length": max((len(line) for line in body_lines), default=0),
        "message_sha256": hashlib.sha256(raw.encode()).hexdigest(),
        "dco": {
            "agent_signoffs": agent_signoffs,
            "human_signoffs": human_signoffs,
            "valid": not agent_signoffs,
        },
        "valid": not errors,
    }
    return evidence, errors


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path("."))
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--inherited-head", help="source PR tip whose author/subject commits are preserved provenance")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        base = git(args.repo, "rev-parse", "--verify", f"{args.base}^{{commit}}").strip()
        head = git(args.repo, "rev-parse", "--verify", f"{args.head}^{{commit}}").strip()
        changed = git(args.repo, "diff", "--name-only", f"{base}...{head}").splitlines()
        shas = git(args.repo, "rev-list", "--reverse", f"{base}..{head}").splitlines()
    except subprocess.CalledProcessError as exc:
        fail(exc.stderr.strip() or "could not resolve commit range")
    if not shas:
        fail("commit range is empty")
    policy = policy_for(args.repo, head, changed)
    agent_identity = configured_agent_identity(args.repo)
    inherited_keys: set[tuple[str, str, str]] = set()
    if args.inherited_head:
        try:
            inherited_head = git(args.repo, "rev-parse", "--verify", f"{args.inherited_head}^{{commit}}").strip()
            fork = git(args.repo, "merge-base", base, inherited_head).strip()
            inherited_shas = git(args.repo, "rev-list", "--reverse", f"{fork}..{inherited_head}").splitlines()
            for inherited_sha in inherited_shas:
                fields = git(args.repo, "show", "-s", "--format=%an%x00%ae", inherited_sha).rstrip("\n").split("\0")
                message = git(args.repo, "show", "-s", "--format=%B", inherited_sha).rstrip("\n")
                inherited_keys.add((fields[0], fields[1], hashlib.sha256(message.encode()).hexdigest()))
        except subprocess.CalledProcessError as exc:
            fail(exc.stderr.strip() or "could not resolve inherited source range")
    commits = []
    violations = []
    for sha in shas:
        raw = git(args.repo, "show", "-s", "--format=%B", sha)
        evidence, errors = validate_message(raw, policy, agent_identity)
        fields = git(args.repo, "show", "-s", "--format=%an%x00%ae", sha).rstrip("\n").split("\0")
        inherited = (fields[0], fields[1], evidence["message_sha256"]) in inherited_keys
        commits.append({"sha": sha, "inherited": inherited, **evidence, "valid": inherited or evidence["valid"]})
        if not inherited:
            violations.extend({"sha": sha, "rule": error} for error in errors)
    report = {
        "schema": "commit-series-quality.v1",
        "base_sha": base,
        "head_sha": head,
        "policy": policy,
        "commits": commits,
        "valid": not violations,
        "violations": violations,
    }
    encoded = json.dumps(report, sort_keys=True, separators=(",", ":")) + "\n"
    if args.output:
        args.output.write_text(encoded)
    else:
        sys.stdout.write(encoded)
    if violations:
        for violation in violations:
            print(f"validate-commit-series: {violation['sha']} {violation['rule']}", file=sys.stderr)
        if any(violation["rule"] == "agent-signed-off-by" for violation in violations):
            print(
                "validate-commit-series: AI attribution is not human DCO certification; "
                "the human publisher must extract the approved change with "
                "`git cherry-pick --no-commit <sha>`, review it, then create a new commit "
                "with their own configured identity and `git commit --signoff`. The "
                "workflow will not rewrite artifact history or invent a human identity.",
                file=sys.stderr,
            )
        raise SystemExit(2)


if __name__ == "__main__":
    main()
