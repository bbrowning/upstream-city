#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

python3 - "$ROOT" <<'PY'
import sys, tomllib
from pathlib import Path

root = Path(sys.argv[1])
formulas = root / "dev-pack/formulas"
expected = {
    "feature-dev.toml": {
        "implementer_target": "feature-dev-frontier-high",
        "review_lane_a_target": "pr-reviewer-a-frontier-high",
        "review_lane_b_target": "pr-reviewer-b-frontier-high",
    },
    "hard-bug-round.toml": {
        "lane_a_id": "bug-lane-a",
        "lane_b_id": "bug-lane-b",
        "lane_a_target": "bug-worker-a-frontier-high",
        "lane_b_target": "bug-worker-b-frontier-high",
        "review_lane_a_target": "pr-reviewer-a-frontier-high",
        "review_lane_b_target": "pr-reviewer-b-frontier-high",
    },
    "hard-bug-round-solo.toml": {
        "lane_a_id": "bug-lane-a",
        "lane_a_target": "bug-worker-a-frontier-high",
        "review_lane_a_target": "pr-reviewer-a-frontier-high",
        "review_lane_b_target": "pr-reviewer-b-frontier-high",
    },
    "hard-bug-finalize.toml": {
        "review_lane_a_target": "pr-reviewer-a-frontier-high",
        "review_lane_b_target": "pr-reviewer-b-frontier-high",
    },
    "change-lifecycle.toml": {
        "lane_a_target": "pr-reviewer-a-frontier-high",
        "lane_b_target": "pr-reviewer-b-frontier-high",
    },
    "change-lifecycle-solo.toml": {
        "lane_a_target": "pr-reviewer-a-frontier-high",
    },
    "pr-review.toml": {"review_target": "pr-reviewer-a-frontier-high"},
    "pr-review-quorum.toml": {
        "lane_a_target": "pr-reviewer-a-frontier-high",
        "lane_b_target": "pr-reviewer-b-frontier-high",
    },
    "pr-review-settle.toml": {
        "arbiter_target": "pr-arbiter",
        "resynth_target": "pr-review-synthesizer",
    },
    "pr-review-dynamic.toml": {"runner_target": "pr-runner"},
    "pr-followup.toml": {"followup_target": "pr-follow-up"},
}
for name, defaults in expected.items():
    data = tomllib.loads((formulas / name).read_text())
    for var, value in defaults.items():
        actual = data["vars"][var].get("default")
        assert actual == value, (name, var, actual, value)
    for step in data["steps"]:
        metadata = step.get("metadata", {})
        assert "gc.provider" not in metadata, (name, step["id"])
        assert "opt_model" not in metadata and "opt_effort" not in metadata, (name, step["id"])

feature = tomllib.loads((formulas / "feature-dev.toml").read_text())
assert feature["steps"][0]["metadata"]["gc.run_target"] == "{{implementer_target}}"
followup = tomllib.loads((formulas / "pr-followup.toml").read_text())
assert followup["steps"][0]["metadata"]["gc.run_target"] == "{{followup_target}}"

legacy = {
    "feature-dev", "bug-worker-a", "bug-worker-b",
    "pr-reviewer-opus48-xhigh", "pr-reviewer-sonnet-xhigh",
    "pr-reviewer-gpt56sol-medium", "pr-reviewer-gpt56sol-xhigh",
    "pr-reviewer-gpt56luna-xhigh", "pr-reviewer-opus46-xhigh",
}
for path in (root / "dev-pack/agents").iterdir():
    assert path.name not in legacy, path
PY

for rig in paude vllm; do
  gc config show --json | jq -e --arg rig "$rig" '
    [.config.Agents[]
      | select(.Dir == $rig)
      | select(.Name == "feature-dev" or .Name == "bug-worker-a" or
               .Name == "bug-worker-b" or
               (.Name | test("^pr-reviewer-(opus|sonnet|gpt)")))]
    | length == 0' >/dev/null || fail "$rig exposes a legacy/generic agent"

  for formula in feature-dev hard-bug-round hard-bug-round-solo hard-bug-finalize \
    change-lifecycle change-lifecycle-solo pr-review pr-review-quorum \
    pr-review-settle pr-review-dynamic pr-followup; do
    gc --rig "$rig" formula show "$formula" --json >"$TMP/$rig-$formula.json"
  done

  jq -e '
    (.vars // .formula.vars) as $vars |
    ($vars | map(select(.name == "implementer_target"))[0].default ==
      "feature-dev-frontier-high") and
    ([.steps[]? // .formula.steps[]?
      | .metadata["gc.run_target"]?] | any(. == "{{implementer_target}}"))' \
    "$TMP/$rig-feature-dev.json" >/dev/null ||
    fail "$rig installed feature formula lost semantic routing"
  jq -e '
    (.vars // .formula.vars) as $vars |
    ($vars | map(select(.name == "lane_a_target"))[0].default ==
      "pr-reviewer-a-frontier-high") and
    ($vars | map(select(.name == "lane_b_target"))[0].default ==
      "pr-reviewer-b-frontier-high")' \
    "$TMP/$rig-pr-review-quorum.json" >/dev/null ||
    fail "$rig installed quorum defaults are not semantic frontier"

  python3 - "$TMP" "$rig" <<'PY'
import json, pathlib, sys

tmp, rig = pathlib.Path(sys.argv[1]), sys.argv[2]
expected = {
    "feature-dev": ({"implementer_target": "feature-dev-frontier-high",
                     "review_lane_a_target": "pr-reviewer-a-frontier-high",
                     "review_lane_b_target": "pr-reviewer-b-frontier-high"},
                    {"{{implementer_target}}", "pr-review-synthesizer"}),
    "hard-bug-round": ({"lane_a_target": "bug-worker-a-frontier-high",
                        "lane_b_target": "bug-worker-b-frontier-high",
                        "coordinator_target": "bug-coordinator",
                        "review_lane_a_target": "pr-reviewer-a-frontier-high",
                        "review_lane_b_target": "pr-reviewer-b-frontier-high"},
                       {"{{lane_a_target}}", "{{lane_b_target}}", "{{coordinator_target}}"}),
    "hard-bug-round-solo": ({"lane_a_target": "bug-worker-a-frontier-high",
                             "coordinator_target": "bug-coordinator",
                             "review_lane_a_target": "pr-reviewer-a-frontier-high",
                             "review_lane_b_target": "pr-reviewer-b-frontier-high"},
                            {"{{lane_a_target}}", "{{coordinator_target}}"}),
    "hard-bug-finalize": ({"review_lane_a_target": "pr-reviewer-a-frontier-high",
                           "review_lane_b_target": "pr-reviewer-b-frontier-high",
                           "coordinator_target": "bug-coordinator"},
                          {"{{implementer_target}}", "pr-review-synthesizer"}),
    "change-lifecycle": ({"lane_a_target": "pr-reviewer-a-frontier-high",
                          "lane_b_target": "pr-reviewer-b-frontier-high",
                          "triage_target": "pr-triage",
                          "synthesis_target": "pr-review-synthesizer",
                          "arbiter_target": "pr-arbiter"},
                         {"{{triage_target}}", "{{lane_a_target}}", "{{lane_b_target}}",
                          "{{synthesis_target}}", "{{arbiter_target}}"}),
    "change-lifecycle-solo": ({"lane_a_target": "pr-reviewer-a-frontier-high",
                               "triage_target": "pr-triage",
                               "synthesis_target": "pr-review-synthesizer"},
                              {"{{triage_target}}", "{{lane_a_target}}", "{{synthesis_target}}"}),
    "pr-review": ({"review_target": "pr-reviewer-a-frontier-high",
                   "triage_target": "pr-triage"},
                  {"{{triage_target}}", "{{review_target}}"}),
    "pr-review-quorum": ({"lane_a_target": "pr-reviewer-a-frontier-high",
                          "lane_b_target": "pr-reviewer-b-frontier-high",
                          "triage_target": "pr-triage",
                          "synthesis_target": "pr-review-synthesizer"},
                         {"{{triage_target}}", "{{lane_a_target}}", "{{lane_b_target}}",
                          "{{synthesis_target}}"}),
    "pr-review-settle": ({"arbiter_target": "pr-arbiter",
                          "resynth_target": "pr-review-synthesizer"},
                         {"{{arbiter_target}}", "{{resynth_target}}"}),
    "pr-review-dynamic": ({"runner_target": "pr-runner"}, {"{{runner_target}}"}),
    "pr-followup": ({"followup_target": "pr-follow-up"}, {"{{followup_target}}"}),
}
for formula, (defaults, routes) in expected.items():
    data = json.loads((tmp / f"{rig}-{formula}.json").read_text())
    actual_defaults = {v["name"]: v.get("default") for v in data["vars"]}
    for name, value in defaults.items():
        assert actual_defaults.get(name) == value, (rig, formula, name, actual_defaults.get(name), value)
    metadata = [s.get("metadata", {}) for s in data["steps"]]
    actual_routes = {m["gc.run_target"] for m in metadata if m.get("gc.run_target")}
    assert routes == actual_routes, (rig, formula, routes, actual_routes)
    for meta in metadata:
        assert "gc.provider" not in meta, (rig, formula, meta)
        assert "opt_model" not in meta and "opt_effort" not in meta, (rig, formula, meta)
PY
done

prompt="$ROOT/dev-pack/agents/bug-coordinator/prompt.template.md"
for token in 'base_ref=<base_ref>' 'lane_a_id=<lane_a_id>' 'lane_b_id=<lane_b_id>' \
  'coordinator_target=<coordinator_target>' 'review_n=<review_n>' \
  'max_review_iterations=<max_review_iterations>' \
  'review_lane_a_target=<review_lane_a_target>' \
  'review_lane_b_target=<review_lane_b_target>' 'base=<base_ref>'; do
  grep -Fq -- "$token" "$prompt" || fail "coordinator re-sling omits $token"
done
! grep -Fq -- 'base=origin/main' "$prompt" || fail "coordinator hardcodes the finalize base"

python3 - "$prompt" <<'PY'
import pathlib, re, sys

text = pathlib.Path(sys.argv[1]).read_text()
blocks = re.findall(r"```bash\n(.*?)\n\s*```", text, re.S)
solo = next((b for b in blocks if "hard-bug-round-solo --formula" in b), None)
assert solo is not None, "coordinator lacks a copy-safe N=1 phase-transition sling"
for token in (
    "base_ref=<base_ref>", "max_rounds=<max_rounds>",
    "lane_a_id=<lane_a_id>", "lane_a_target=<lane_a_target>",
    "coordinator_target=<coordinator_target>", "branch_prefix=<branch_prefix>",
    "review_n=<review_n>", "max_review_iterations=<max_review_iterations>",
    "review_lane_a_target=<review_lane_a_target>",
    "review_lane_b_target=<review_lane_b_target>",
):
    assert token in solo, f"N=1 coordinator sling omits {token}"
for forbidden in ("--var lane_b_id=", "--var lane_b_target=", "prior_peer_bead_", "relay_note_"):
    assert forbidden not in solo, f"N=1 coordinator sling includes {forbidden}"
PY

printf 'execution wiring contract: ok\n'
