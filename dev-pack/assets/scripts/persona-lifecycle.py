#!/usr/bin/env python3
"""Select lifecycle personas and enforce the corpus/lens governance contract."""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
from pathlib import Path

LENSES = {"diagnosis", "design", "implementation", "change-review", "settle"}
FILE_WORD_BUDGET = 1800
CORPUS_WORD_BUDGET = 5000


def die(message: str) -> None:
    raise SystemExit(f"persona lifecycle: {message}")


def duplicate_safe_json(path: Path):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                die(f"duplicate lens or key {key!r} in {path}")
            result[key] = value
        return result

    try:
        return json.loads(path.read_text(), object_pairs_hook=pairs)
    except (OSError, json.JSONDecodeError) as exc:
        die(f"cannot read {path}: {exc}")


def persona_files(corpus: Path) -> list[Path]:
    files = sorted(corpus.glob("*.md"))
    base = corpus / "base.md"
    if base not in files:
        die(f"missing required {base}")
    return [base, *(path for path in files if path != base)]


def activation_text(path: Path) -> str:
    lines = path.read_text().splitlines()
    for index, line in enumerate(lines):
        if line.startswith("**Activates on:**"):
            parts = [line.split(":**", 1)[-1] if ":**" in line else line.partition(":")[2]]
            for following in lines[index + 1 :]:
                if not following.strip():
                    break
                parts.append(following)
            return " ".join(parts)
    die(f"{path} has no **Activates on:** header")


def expand_braces(pattern: str) -> list[str]:
    match = re.search(r"\{([^{}]+)\}", pattern)
    if not match:
        return [pattern]
    expanded = []
    for choice in match.group(1).split(","):
        expanded.extend(expand_braces(pattern[: match.start()] + choice + pattern[match.end() :]))
    return expanded


def activation_patterns(path: Path) -> list[str]:
    if path.name == "base.md":
        return ["*"]
    patterns = []
    for quoted in re.findall(r"`([^`]+)`", activation_text(path)):
        patterns.extend(expand_braces(quoted.rstrip("/")))
    if not patterns:
        die(f"{path} has no backtick-delimited activation paths")
    return patterns


def matches(pattern: str, candidate: str) -> bool:
    candidate = candidate.removeprefix("./").rstrip("/")
    return candidate == pattern or candidate.startswith(pattern + "/") or fnmatch.fnmatch(candidate, pattern)


def select(corpus: Path, lens: str, candidates: list[str]) -> list[Path]:
    if lens not in LENSES:
        die(f"unknown lens {lens!r}; expected one of {', '.join(sorted(LENSES))}")
    selected = []
    for path in persona_files(corpus):
        if path.name == "base.md" or any(
            matches(pattern, candidate)
            for pattern in activation_patterns(path)
            for candidate in candidates
        ):
            selected.append(path)
    return selected


def govern(corpus: Path, pack_root: Path, registry_path: Path, coverage_path: Path, cases_dir: Path) -> None:
    files = persona_files(corpus)
    total_words = 0
    activation_sets: dict[tuple[str, ...], Path] = {}
    for path in files:
        words = len(re.findall(r"\b[\w'-]+\b", path.read_text()))
        if words > FILE_WORD_BUDGET:
            die(f"{path} exceeds {FILE_WORD_BUDGET}-word budget ({words})")
        total_words += words
        patterns = tuple(sorted(activation_patterns(path)))
        if path.name != "base.md" and patterns in activation_sets:
            die(f"duplicate activation domain in {activation_sets[patterns]} and {path}")
        activation_sets[patterns] = path
    if total_words > CORPUS_WORD_BUDGET:
        die(f"corpus exceeds {CORPUS_WORD_BUDGET}-word budget ({total_words})")

    coverage = duplicate_safe_json(coverage_path)
    reflexes = {
        f"{path.stem}.{match.group(1)}"
        for path in files
        for match in re.finditer(r"(?m)^(\d+)\.\s+\*\*", path.read_text())
    }
    if set(coverage) != reflexes:
        die(
            "reflex coverage mismatch: "
            f"missing={sorted(reflexes - set(coverage))} orphan={sorted(set(coverage) - reflexes)}"
        )
    for reflex, cases in coverage.items():
        if not isinstance(cases, list) or not cases:
            die(f"reflex {reflex!r} has no regression case")
        for case in cases:
            if not (cases_dir / case / "meta.json").is_file() or not (cases_dir / case / "answer-key.md").is_file():
                die(f"reflex {reflex!r} names missing/incomplete regression case {case!r}")

    registry = duplicate_safe_json(registry_path)
    actual = set(registry)
    if actual != LENSES:
        die(f"lens registry mismatch: missing={sorted(LENSES - actual)} orphan={sorted(actual - LENSES)}")
    for lens, spec in registry.items():
        consumers = spec.get("consumers", [])
        if not consumers:
            die(f"orphan lens {lens!r} has no consumers")
        marker = '{{template "persona-load" "' + lens + '"}}'
        for relative in consumers:
            consumer = pack_root / relative
            if not consumer.is_file() or marker not in consumer.read_text():
                die(f"lens {lens!r} missing declared consumer marker in {consumer}")

    print(f"persona governance: ok ({len(files)} files, {total_words}/{CORPUS_WORD_BUDGET} words, 5 lenses)")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    choose = sub.add_parser("select")
    choose.add_argument("--corpus", type=Path, required=True)
    choose.add_argument("--lens", required=True)
    choose.add_argument("--path", action="append", default=[])
    check = sub.add_parser("govern")
    check.add_argument("--corpus", type=Path, required=True)
    check.add_argument("--pack-root", type=Path, required=True)
    check.add_argument("--registry", type=Path, required=True)
    check.add_argument("--coverage", type=Path, required=True)
    check.add_argument("--cases", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "select":
        for path in select(args.corpus, args.lens, args.path):
            print(path)
    else:
        govern(args.corpus, args.pack_root, args.registry, args.coverage, args.cases)


if __name__ == "__main__":
    main()
