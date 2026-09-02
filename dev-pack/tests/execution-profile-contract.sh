#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
POLICY="$ROOT/dev-pack/assets/workflow-policy.json"
VALIDATE="$ROOT/dev-pack/assets/scripts/validate-execution-profile.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

python3 - "$ROOT" "$POLICY" <<'PY'
import json, sys, tomllib
from pathlib import Path
root, policy_path = Path(sys.argv[1]), Path(sys.argv[2])
p = json.loads(policy_path.read_text())
expected = {'frontier-xhigh', 'frontier-high', 'frontier-medium', 'efficient-xhigh', 'efficient-medium'}
assert set(p['execution_profiles']) == expected
assert p['defaults']['execution_profile'] == 'frontier-high'
for name, profile in p['execution_profiles'].items():
    assert profile['semantics']
    assert profile['reasoning_effort'] in {'medium', 'high', 'xhigh'}
    assert name.endswith('-' + profile['reasoning_effort'])
    roles = profile['roles']
    assert set(roles) == {'feature', 'bug', 'review'}
    assert set(roles['feature']) == {'implementer'}
    assert set(roles['bug']) == {'lane_a', 'lane_b'}
    assert set(roles['review']) == {'solo', 'lane_a', 'lane_b'}
    assert roles['bug']['lane_a'] != roles['bug']['lane_b']
    assert roles['review']['lane_a'] != roles['review']['lane_b']

city = tomllib.loads((root / 'city.toml').read_text())
fixed = {
    'pr-triage': ('codex', 'gpt-5.6-sol', 'medium'),
    'pr-review-synthesizer': ('codex', 'gpt-5.6-sol', 'medium'),
    'pr-arbiter': ('codex', 'gpt-5.6-sol', 'xhigh'),
    'pr-runner': ('codex', 'gpt-5.6-luna', 'high'),
    'pr-follow-up': ('codex', 'gpt-5.6-sol', 'high'),
    'pr-chat': ('codex', 'gpt-5.6-sol', 'high'),
    'bug-coordinator': ('codex', 'gpt-5.6-sol', 'high'),
}
for rig in city['rigs']:
    patch_list = rig.get('patches', [])
    patches = {x.get('agent'): x for x in patch_list}
    assert len(patches) == len(patch_list), (rig['name'], 'duplicate patch')
    semantic_targets = {
        t for profile in p['execution_profiles'].values()
        for group in profile['roles'].values() for t in group.values()
    }
    assert len(semantic_targets) == 25
    assert set(patches) == set(fixed) | semantic_targets, (
        rig['name'], sorted(set(patches) - set(fixed) - semantic_targets),
        sorted((set(fixed) | semantic_targets) - set(patches)))
    assert len(patches) == 32, (rig['name'], len(patches))
    for agent, expected_binding in fixed.items():
        patch = patches[agent]
        actual = (patch['provider'], patch['option_defaults']['model'], patch['option_defaults']['effort'])
        assert actual == expected_binding, (rig['name'], agent, actual, expected_binding)
    for profile_name, profile in p['execution_profiles'].items():
        targets = {t for group in profile['roles'].values() for t in group.values()}
        for target in targets:
            patch = patches[target]
            assert patch['provider']
            assert patch['option_defaults']['model']
            assert patch['option_defaults']['effort'] == profile['reasoning_effort']
            lane_b = target.startswith('bug-worker-b-') or target.startswith('pr-reviewer-b-')
            if profile_name.startswith('frontier-') and lane_b:
                assert (patch['provider'], patch['option_defaults']['model']) == ('claude', 'claude-opus-4-8')
            elif profile_name.startswith('frontier-'):
                assert (patch['provider'], patch['option_defaults']['model']) == ('codex', 'gpt-5.6-sol')
            else:
                assert (patch['provider'], patch['option_defaults']['model']) == ('codex', 'gpt-5.6-luna')
            shell = root / 'dev-pack' / 'agents' / target / 'agent.toml'
            data = tomllib.loads(shell.read_text())
            assert data['prompt_template']
            assert 'provider' not in data and 'option_defaults' not in data
            if patch['provider'] == 'claude':
                assert profile_name.startswith('frontier-') and lane_b, (rig['name'], target)
PY

! rg -n 'opus46|opus-4-6|Opus 4\.6|pr-reviewer-(opus48|sonnet|gpt56)|reviewer_target|opt_model|opt_effort' \
  "$ROOT/city.toml" "$ROOT/dev-pack/agents" "$ROOT/dev-pack/formulas" "$ROOT/dev-pack/assets" \
  "$ROOT/dev-pack/commands" "$ROOT/dev-pack/README.md" "$ROOT/docs" "$ROOT/README.md" \
  --glob '!dev-pack/tests/execution-profile-contract.sh' \
  || fail 'legacy concrete/generic execution wiring remains'

for rig in paude vllm; do
  for profile in frontier-xhigh frontier-high frontier-medium efficient-xhigh efficient-medium; do
    python3 "$VALIDATE" --city "$ROOT" --policy "$POLICY" --rig "$rig" --profile "$profile" >/dev/null
  done
done

cat >"$TMP/gc" <<'GC'
#!/usr/bin/env bash
if [[ " $* " == *" rig list --json "* ]]; then
  jq -cn --arg path "$MOCK_ROOT" '{rigs:[{name:"paude",path:$path},{name:"vllm",path:$path}]}'
elif [[ " $* " == *" agent list "* ]]; then
  for rig in paude vllm; do
    printf '%s\n' "$rig/pr-review-synthesizer" "$rig/bug-coordinator"
    printf '%s\n' "$rig/custom-implementer" "$rig/custom-review-a" "$rig/custom-review-b"
    jq -r --arg rig "$rig" '.execution_profiles[].roles.review[] | "\($rig)/\(.)"' "$MOCK_POLICY"
  done | sort -u
else
  exit 99
fi
GC
chmod +x "$TMP/gc"

for command in feature bug; do
  out=$(GC_BIN=gc "$ROOT/dev-pack/commands/$command/run.sh" paude-1 --rig paude --execution efficient-medium --dry-run)
  grep -q 'execution=efficient-medium' <<<"$out" || fail "$command hid execution profile"
  grep -q 'efficient-medium' <<<"$out" || fail "$command hid resolved targets"
done

feature_override=$(MOCK_ROOT="$ROOT" MOCK_POLICY="$POLICY" GC_BIN="$TMP/gc" GC_CITY_PATH="$ROOT" \
  "$ROOT/dev-pack/commands/feature/run.sh" paude-1 --rig paude \
  --execution efficient-medium --implementer-target paude/custom-implementer \
  --review-lanes paude/custom-review-a,paude/custom-review-b --dry-run)
for expected in 'execution=efficient-medium' 'implementer_target=paude/custom-implementer' \
  'review_lane_a_target=paude/custom-review-a'; do
  grep -q "$expected" <<<"$feature_override" || fail "feature override precedence lost $expected"
done

out=$(MOCK_ROOT="$ROOT" MOCK_POLICY="$POLICY" GC_BIN="$TMP/gc" GC_CITY_PATH="$ROOT" \
  "$ROOT/dev-pack/commands/review/run.sh" 123 --rig paude --execution efficient-medium --n 2 --dry-run)
grep -q 'execution=efficient-medium' <<<"$out" || fail 'review hid execution profile'
grep -q 'pr-reviewer-a-efficient-medium' <<<"$out" || fail 'review lost profile lane A'
grep -q 'pr-reviewer-b-efficient-medium' <<<"$out" || fail 'review lost profile lane B'
review_override=$(MOCK_ROOT="$ROOT" MOCK_POLICY="$POLICY" GC_BIN="$TMP/gc" GC_CITY_PATH="$ROOT" \
  "$ROOT/dev-pack/commands/review/run.sh" 123 --rig paude --execution efficient-medium \
  --lanes custom-review-a,custom-review-b --dry-run)
grep -q 'execution=efficient-medium' <<<"$review_override" || fail 'review override hid execution profile'
grep -q 'lane_a_target=paude/custom-review-a' <<<"$review_override" || fail 'review lane A override lost'
grep -q 'lane_b_target=paude/custom-review-b' <<<"$review_override" || fail 'review lane B override lost'
if MOCK_ROOT="$ROOT" MOCK_POLICY="$POLICY" GC_BIN="$TMP/gc" GC_CITY_PATH="$ROOT" \
  "$ROOT/dev-pack/commands/review/run.sh" 123 --rig paude \
  --lanes sonnet-xhigh --dry-run >"$TMP/legacy-lane" 2>&1; then
  fail 'legacy concrete reviewer name remained launchable'
fi
grep -q "unknown reviewer target 'sonnet-xhigh'" "$TMP/legacy-lane" \
  || fail 'legacy reviewer failure lacks migration context'

# Shape is orthogonal: an inexpensive run retains two diagnosis and review leaves.
demo=$(GC_BIN=gc "$ROOT/dev-pack/commands/bug/run.sh" paude-1 --rig paude --n 2 \
  --review-n 2 --execution efficient-medium --dry-run)
for expected in 'diagnosis_n=2' 'review_n=2' 'bug-worker-a-efficient-medium' 'bug-worker-b-efficient-medium'; do
  grep -q "$expected" <<<"$demo" || fail "efficient N=2 demo lost $expected"
done

# Explicit targets win without changing the named capacity profile or topology.
override=$(MOCK_ROOT="$ROOT" MOCK_POLICY="$POLICY" GC_BIN="$TMP/gc" GC_CITY_PATH="$ROOT" \
  "$ROOT/dev-pack/commands/bug/run.sh" paude-1 --rig paude \
  --execution efficient-medium --lane-a-target paude/custom-review-a --lane-b-target paude/custom-review-b \
  --review-lanes paude/custom-review-a,paude/custom-review-b --dry-run)
for expected in 'execution=efficient-medium' 'lane_a_target=paude/custom-review-a' \
  'lane_b_target=paude/custom-review-b' 'review_lane_a_target=paude/custom-review-a'; do
  grep -q "$expected" <<<"$override" || fail "override precedence lost $expected"
done

for command_and_args in \
  'feature paude-1 --rig paude --implementer-target paude/feature-dev' \
  'bug paude-1 --rig paude --lane-a-target paude/bug-worker-a' \
  'bug paude-1 --rig paude --review-lanes paude/pr-reviewer-sonnet-xhigh,paude/pr-reviewer-gpt56luna-xhigh'; do
  read -r -a argv <<<"$command_and_args"
  command=${argv[0]}
  if MOCK_ROOT="$ROOT" MOCK_POLICY="$POLICY" GC_BIN="$TMP/gc" GC_CITY_PATH="$ROOT" \
    "$ROOT/dev-pack/commands/$command/run.sh" "${argv[@]:1}" --dry-run >"$TMP/$command-legacy" 2>&1; then
    fail "$command accepted removed execution target(s): ${argv[*]:1}"
  fi
  grep -q 'unknown installed target' "$TMP/$command-legacy" \
    || fail "$command legacy target failure is unclear"
done

for command_and_args in \
  'feature paude-1 --rig paude --implementer-target vllm/feature-dev-frontier-xhigh' \
  'feature paude-1 --rig paude --review-lanes vllm/pr-reviewer-a-frontier-xhigh,vllm/pr-reviewer-b-frontier-xhigh' \
  'bug paude-1 --rig paude --lane-a-target vllm/bug-worker-a-frontier-xhigh' \
  'bug paude-1 --rig paude --review-lanes vllm/pr-reviewer-a-frontier-xhigh,vllm/pr-reviewer-b-frontier-xhigh'; do
  read -r -a argv <<<"$command_and_args"
  command=${argv[0]}
  if GC_BIN=gc "$ROOT/dev-pack/commands/$command/run.sh" "${argv[@]:1}" --dry-run \
    >"$TMP/$command-cross-rig" 2>&1; then
    fail "$command accepted cross-rig execution target(s): ${argv[*]:1}"
  fi
  grep -q 'belongs to a different rig' "$TMP/$command-cross-rig" \
    || fail "$command cross-rig target failure is unclear"
done

if GC_BIN=gc "$ROOT/dev-pack/commands/feature/run.sh" paude-1 --rig paude --execution unknown --dry-run >"$TMP/unknown" 2>&1; then
  fail 'unknown execution profile was accepted'
fi
grep -q "unknown profile 'unknown'" "$TMP/unknown" || fail 'unknown profile error is unclear'

cat >"$TMP/bad-city.toml" <<'TOML'
[[rigs]]
name = "paude"
[[rigs.patches]]
agent = "bug-worker-a-frontier-xhigh"
provider = "codex"
option_defaults = { model = "gpt-5.6-sol" }
TOML
if python3 "$VALIDATE" --city "$TMP/bad-city.toml" --policy "$POLICY" --rig paude --profile frontier-xhigh >"$TMP/bad" 2>&1; then
  fail 'missing/misbound semantic role set was accepted'
fi
grep -Eq 'no explicit|provider, model, and effort' "$TMP/bad" || fail 'misbinding error is unclear'

cat >"$TMP/good-city.toml" <<'TOML'
[providers.codex]
base = "builtin:codex"
[providers.claude]
base = "builtin:claude"
[[rigs]]
name = "paude"
[[rigs.patches]]
agent = "bug-worker-a-frontier-xhigh"
provider = "codex"
option_defaults = { model = "gpt-5.6-sol", effort = "xhigh" }
[[rigs.patches]]
agent = "bug-worker-b-frontier-xhigh"
provider = "claude"
option_defaults = { model = "claude-opus-4-8", effort = "xhigh" }
[[rigs.patches]]
agent = "feature-dev-frontier-xhigh"
provider = "codex"
option_defaults = { model = "gpt-5.6-sol", effort = "xhigh" }
[[rigs.patches]]
agent = "pr-reviewer-a-frontier-xhigh"
provider = "codex"
option_defaults = { model = "gpt-5.6-sol", effort = "xhigh" }
[[rigs.patches]]
agent = "pr-reviewer-b-frontier-xhigh"
provider = "claude"
option_defaults = { model = "claude-opus-4-8", effort = "xhigh" }
TOML
sed '0,/effort = "xhigh"/s//effort = "medium"/' "$TMP/good-city.toml" >"$TMP/wrong-effort.toml"
if python3 "$VALIDATE" --city "$TMP/wrong-effort.toml" --policy "$POLICY" --rig paude \
  --profile frontier-xhigh >"$TMP/effort" 2>&1; then
  fail 'wrong non-empty semantic effort was accepted'
fi
grep -q "requires 'xhigh'" "$TMP/effort" || fail 'wrong-effort error is unclear'

sed '0,/provider = "codex"/s//provider = "missing"/' "$TMP/good-city.toml" >"$TMP/wrong-provider.toml"
if python3 "$VALIDATE" --city "$TMP/wrong-provider.toml" --policy "$POLICY" --rig paude \
  --profile frontier-xhigh >"$TMP/provider" 2>&1; then
  fail 'unconfigured provider was accepted'
fi
grep -q "unconfigured provider 'missing'" "$TMP/provider" || fail 'provider error is unclear'

for file in "$ROOT/dev-pack/commands/bug/help.md" "$ROOT/dev-pack/commands/feature/help.md" \
  "$ROOT/dev-pack/commands/review/help.md" "$ROOT/dev-pack/README.md"; do
  ! grep -Eq -- '--models|--lane-a-model|--lane-b-model|per-run models' "$file" \
    || fail "stale per-run model claim remains in $file"
done
for file in "$ROOT/dev-pack/pack.toml" \
  "$ROOT/dev-pack/assets/prompts/bug-worker.prompt.template.md" \
  "$ROOT/dev-pack/agents/bug-coordinator/prompt.template.md" \
  "$ROOT/dev-pack/agents/pr-review-synthesizer/prompt.template.md" \
  "$ROOT/dev-pack/formulas/pr-review-quorum.toml"; do
  ! grep -Eq 'different models|different models/providers|a different model' "$file" \
    || fail "stale guaranteed model-diversity claim remains in $file"
done
if GC_BIN=gc "$ROOT/dev-pack/commands/bug/run.sh" paude-1 --rig paude --models opus,sonnet >"$TMP/model" 2>&1; then
  fail 'inert model flag was silently accepted'
fi
grep -q 'not a reliable launch override' "$TMP/model" || fail 'inert model flag lacks migration guidance'

printf 'execution profile contract: ok\n'
