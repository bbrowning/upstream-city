#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

# Assignment retries start a session for the step's gc.run_target, so the
# target agent's nudge is the reminder the step receives. Resolve that wiring
# from formula metadata and pin every review workflow role to its own contract.
python3 - "$ROOT" <<'PY'
import sys
import tomllib
from pathlib import Path

root = Path(sys.argv[1])
pack = root / "dev-pack"


def load(relative):
    return tomllib.loads((pack / relative).read_text())


def nudge(agent):
    return load(f"agents/{agent}/agent.toml")["nudge"]


def step(formula, step_id):
    data = load(f"formulas/{formula}.toml")
    return data, next(item for item in data["steps"] if item["id"] == step_id)


def default_target(formula, item):
    raw = item["metadata"]["gc.run_target"]
    if raw.startswith("{{") and raw.endswith("}}"):
        return formula["vars"][raw[2:-2]]["default"]
    return raw


def assert_route(formula_name, step_id, target, schema, required, forbidden=()):
    formula, item = step(formula_name, step_id)
    actual_target = default_target(formula, item)
    assert actual_target == target, (formula_name, step_id, actual_target, target)
    assert item["metadata"]["gc.output_json_schema"] == schema
    reminder = nudge(target)
    for text in required:
        assert text in reminder, (target, text, reminder)
    for text in forbidden:
        assert text not in reminder, (target, text, reminder)


assert_route(
    "pr-review-quorum", "triage", "pr-triage", "pr-triage.v1",
    ("Triage assignment", "pr-triage.v1"),
    ("pr-review.v1", "pr-review-quorum.v1", "pr-review-settle.v1"),
)
assert_route(
    "pr-review-quorum", "review-lane-a", "pr-reviewer-a-frontier-xhigh",
    "pr-review.v1", ("review lane assignment", "pr-review.v1"),
    ("pr-review-quorum.v1", "pr-review-settle.v1"),
)
assert_route(
    "pr-review-quorum", "review-lane-b", "pr-reviewer-b-frontier-xhigh",
    "pr-review.v1", ("review lane assignment", "pr-review.v1"),
    ("pr-review-quorum.v1", "pr-review-settle.v1"),
)
assert_route(
    "pr-review-quorum", "synthesize", "pr-review-synthesizer",
    "pr-review-quorum.v1", ("quorum synthesis assignment", "upstream lane verdicts", "pr-review-quorum.v1"),
    ("pr-review.v1", "review the diff", "pr-review-settle.v1"),
)
assert_route(
    "pr-review-settle", "arbitrate", "pr-arbiter", "pr-review-settle.v1",
    ("settle assignment", "pr-review-settle.v1"),
    ("pr-review-quorum.v1",),
)
assert_route(
    "pr-review-settle", "re-synthesize", "pr-review-synthesizer",
    "pr-review-quorum.v1", ("quorum synthesis assignment", "upstream lane verdicts", "pr-review-quorum.v1"),
    ("pr-review.v1", "review the diff", "pr-review-settle.v1"),
)

# A solo review routes to a reviewer role, never to the synthesis role.
assert_route(
    "pr-review", "review", "pr-reviewer-a-frontier-xhigh", "pr-review.v1",
    ("review lane assignment", "pr-review.v1"), ("pr-review-quorum.v1",),
)
PY

printf 'review assignment reminders: ok\n'
