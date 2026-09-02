#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
POLICY="$ROOT/dev-pack/assets/workflow-policy.json"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The policy is authoritative; formulas are static TOML consumers and must fail here
# when a policy default changes without updating them.
python3 - "$ROOT" "$POLICY" <<'PY'
import json, sys, tomllib
from pathlib import Path
root, policy_path = Path(sys.argv[1]), Path(sys.argv[2])
p = json.loads(policy_path.read_text())
assert p['schema'] == 'dev-pack-workflow-policy.v2'
assert p['defaults']['local_only'] is True
assert p['defaults']['completion_checkpoint'] == 'approved'
assert p['defaults']['dynamic_verification'] == {
    'max_checks': 3, 'max_coverage_axes': 2, 'max_followups': 1,
    'total_timeout_s': 600, 'total_output_cap_bytes': 65536,
}
gate = (root / 'dev-pack/assets/scripts/run-dynamic-verification.sh').read_text()
for key, shell_name in (
    ('max_checks', 'MAX_CHECKS'), ('max_coverage_axes', 'MAX_COVERAGE'),
    ('total_timeout_s', 'TOTAL_TIMEOUT'), ('total_output_cap_bytes', 'TOTAL_CAP'),
):
    assert f'{shell_name}={p["defaults"]["dynamic_verification"][key]}' in gate
assert p['presets']['quality']['feature'] == {'review_n': 2, 'formula': 'feature-dev'}
assert p['presets']['quality']['bug']['formula'] == 'hard-bug-round'
assert p['presets']['quality']['review'] == {'n': 2, 'formula': 'pr-review-quorum', 'enable_settle': True}
assert p['presets']['report_only']['bug']['completion_checkpoint'] == 'report_only'

formulas = root / 'dev-pack/formulas'
name = 'feature-dev.toml'
d = tomllib.loads((formulas/name).read_text())
assert int(d['vars']['review_n']['default']) == p['presets']['quality']['feature']['review_n'], name
assert int(d['vars']['max_review_iterations']['default']) == p['defaults']['max_review_iterations'], name
for name in ('hard-bug-finalize.toml', 'hard-bug-round.toml', 'hard-bug-round-solo.toml'):
    d = tomllib.loads((formulas/name).read_text())
    assert int(d['vars']['review_n']['default']) == p['presets']['quality']['bug']['review_n'], name
    assert int(d['vars']['max_review_iterations']['default']) == p['defaults']['max_review_iterations'], name
d = tomllib.loads((formulas/'pr-review-dynamic.toml').read_text())
assert 'plan_json' in d['vars']
assert 'run-dynamic-verification.sh' in d['steps'][0]['description']
for name in ('hard-bug-finalize.toml', 'hard-bug-round.toml', 'hard-bug-round-solo.toml'):
    d = tomllib.loads((formulas/name).read_text())
    assert int(d['vars']['max_rounds']['default']) == p['defaults']['max_rounds'], name
for name in ('change-lifecycle.toml', 'change-lifecycle-solo.toml'):
    d = tomllib.loads((formulas/name).read_text())
    assert int(d['vars']['max_iterations']['default']) == p['defaults']['max_review_iterations'], name
PY

feature=$(GC_BIN=gc "$ROOT/dev-pack/commands/feature/run.sh" paude-feature --rig paude --dry-run)
bug=$(GC_BIN=gc "$ROOT/dev-pack/commands/bug/run.sh" paude-bug --rig paude --dry-run)
for expected in 'preset=quality' 'review_n=2' 'max_review_iterations=3' 'local_only=true' 'completion=approved'; do
  printf '%s' "$feature" | grep -q "$expected" || fail "feature dry-run drift: $expected"
done
for expected in 'preset=quality' 'diagnosis_n=2' 'loop=true' 'review_n=2' 'max_rounds=3' 'max_review_iterations=3' 'local_only=true'; do
  printf '%s' "$bug" | grep -q "$expected" || fail "bug dry-run drift: $expected"
done

cat >"$TMP/gc" <<GC
#!/usr/bin/env bash
args=" \$* "
if [[ "\$args" == *" rig list --json "* ]]; then
  jq -cn --arg path "$ROOT" '{rigs:[{name:"paude",path:\$path}]}'
elif [[ "\$args" == *" agent list "* ]]; then
  printf '%s\n' paude/pr-review-synthesizer paude/pr-reviewer-a-frontier-high paude/pr-reviewer-b-frontier-high
else
  exit 99
fi
GC
chmod +x "$TMP/gc"
review=$(GC_BIN="$TMP/gc" GC_CITY_PATH="$ROOT" "$ROOT/dev-pack/commands/review/run.sh" 123 --rig paude --dry-run)
for expected in 'preset=quality' 'n=2' 'settle=true' 'enable_settle=true' 'pr-review-quorum --formula' 'completion=human_checkpoint'; do
  printf '%s' "$review" | grep -q "$expected" || fail "review dry-run drift: $expected"
done

# Every accepted workflow flag must be visible in the supported pack-command help.
for spec in \
  'feature:--quality --fast --solo --execution --review-n --review-lanes --max-review-iterations --dry-run' \
  'bug:--quality --fast --solo --report-only --execution --n --loop --max-rounds --review-n --review-lanes --dry-run' \
  'review:--quality --fast --solo --no-settle --report-only --execution --n --lanes --artifact --dry-run'; do
  command=${spec%%:*}; flags=${spec#*:}
  help=$(gc dev-pack "$command" --help)
  for flag in $flags; do
    printf '%s' "$help" | grep -q -- "$flag" || fail "$command help hides $flag"
    grep -q -- "$flag" "$ROOT/dev-pack/commands/$command/run.sh" || fail "$command parser lacks documented $flag"
  done
done

# Ask must expose both supported modes, including their different durability.
ask_help=$(gc dev-pack ask --help)
for phrase in 'question present' 'no question' 'terminal required' 'Ctrl-b d' \
  'One reattachable session per PR' 'emits, closes, and mails nothing' \
  'original review verdict' 'prior asynchronous Q&A'; do
  printf '%s' "$ask_help" | grep -Fq -- "$phrase" || fail "ask help missing two-mode contract: $phrase"
done
for phrase in 'gc dev-pack ask 51296 "does this handle empty batches?"' \
  'gc dev-pack ask 51296' 'one persistent coding-assistant session per PR' \
  'Requires a terminal' 'Ctrl-b d' 'emits no result bead' \
  'original verdict and every earlier asynchronous Q&A'; do
  grep -Fq -- "$phrase" "$ROOT/dev-pack/README.md" \
    || fail "canonical guide missing ask contract: $phrase"
done

# Work is the canonical read-only attention contract, including its explicit watch
# deferral rather than an accidental polling implementation.
work_help=$(gc dev-pack work --help)
feedback_help=$(gc dev-pack feedback --help)
reconcile_help=$(gc dev-pack reconcile --help)
plan_help=$(gc dev-pack plan --help)
for phrase in 'human-facing' 'GC_ATTENTION_ACTORS' 'NEEDS YOU' 'bd' '--readonly' \
  'never reads or acknowledges mail' 'explicitly deferred'; do
  printf '%s' "$work_help" | grep -Fq -- "$phrase" || fail "work help missing attention contract: $phrase"
done
printf '%s' "$feedback_help" | grep -Fq -- 'newest authoritative finished review' \
  || fail 'feedback help missing upstream rendering contract'
printf '%s' "$reconcile_help" | grep -Fq -- 'Always refreshes GitHub read-only' \
  || fail 'reconcile help missing verification contract'
for phrase in 'CONDITION  ci | author' 'ACTION     approve | request-changes | re-review | inspect' \
  'Valid combinations' '--note' '--cancel' 'never reads or harvests'; do
  printf '%s' "$plan_help" | grep -Fq -- "$phrase" || fail "plan help missing explicit-plan contract: $phrase"
done
for phrase in '## Human attention desk' 'gc dev-pack work show' \
  'gc dev-pack feedback' 'gc dev-pack reconcile' 'gc dev-pack plan' \
  'STALE OR UNCLEAR' 'no parallel attention state' '--watch'; do
  grep -Fq -- "$phrase" "$ROOT/dev-pack/README.md" \
    || fail "operator runbook missing attention contract: $phrase"
done

docs=$(printf '%s\n' "$ROOT/README.md" "$ROOT/dev-pack/README.md")
for phrase in 'Implement this feature' 'Fix this bug' 'Review PR N'; do
  grep -q "$phrase" $docs || fail "quickstart missing human request: $phrase"
done
for phrase in 'N=2 independent review' 'strict synthesis' 'evidence settlement' \
  'maximum 3 revisions' 'branch + exact HEAD SHA' 'gc.lead_escalation_json' \
  'Copy-paste verification' 'local-only' 'AI attribution is not DCO certification' \
  'git cherry-pick --no-commit'; do
  grep -q "$phrase" "$ROOT/dev-pack/README.md" || fail "canonical guide missing lifecycle contract: $phrase"
done

# Every write and revision contract forbids agent DCO certification and gives the
# human publisher an explicit safe handoff. Static contract coverage complements
# the executable artifact-boundary tests.
for relative in \
  'assets/prompts/feature-dev.prompt.template.md' \
  'assets/prompts/bug-worker.prompt.template.md' \
  'formulas/feature-dev.toml' \
  'formulas/hard-bug-finalize.toml'; do
  file="$ROOT/dev-pack/$relative"
  grep -Fq 'Signed-off-by' "$file" || fail "$relative lacks the agent DCO prohibition"
  grep -Fq 'never add' "$file" \
    || fail "$relative does not explicitly prohibit adding an agent sign-off"
  grep -Fq 'DCO' "$file" || fail "$relative does not distinguish DCO certification"
  grep -Fq 'human publisher' "$file" || fail "$relative lacks human publication guidance"
done
for relative in 'formulas/change-lifecycle.toml' 'formulas/change-lifecycle-solo.toml'; do
  file="$ROOT/dev-pack/$relative"
  grep -Fq 'Every revision' "$file" || fail "$relative loses the DCO guard on revision"
  grep -Fq 'DCO-ready' "$file" || fail "$relative can mislabel approval as DCO-ready"
  grep -Fq 'human publisher' "$file" || fail "$relative lacks final human handoff guidance"
done
for phrase in '## Presets and defaults' '## Feature work' '## Hard-bug work' \
  '## Review a PR or local change' '### Materialize a reviewed PR' \
  '## Human attention desk' \
  '## Monitor and retrieve results' '## Recovery and escalation' \
  'gc dev-pack bug vllm-456 --report-only' 'gc dev-pack status vllm-456' \
  'gc dev-pack review --artifact' 'gc dev-pack materialize 53174'; do
  grep -Fq -- "$phrase" "$ROOT/dev-pack/README.md" \
    || fail "operator runbook missing current workflow content: $phrase"
done

# The canonical README stays an operator runbook, not an inventory/design/backlog dump.
[ "$(wc -l < "$ROOT/dev-pack/README.md")" -le 350 ] \
  || fail 'canonical operator runbook grew beyond 350 lines'
! rg -n -- '## What.s here|## Growing up|Remaining: Phase 3|Quorum: add a second reviewer|Review local commits / working-tree changes' \
  "$ROOT/dev-pack/README.md" "$ROOT/docs/dev-pack-design.md" >/dev/null \
  || fail 'maintained docs contain removed inventory or implemented-as-future claims'
for phrase in '## Worktree isolation and reaping' '## Durable schemas and closure' \
  '## Review posture and dynamic execution' '## Personas'; do
  grep -Fq -- "$phrase" "$ROOT/docs/dev-pack-design.md" \
    || fail "design reference missing durable internals: $phrase"
done
grep -Fq -- '## Enable dev-pack on the rig' "$ROOT/docs/rig-bootstrap.md" \
  || fail 'rig bootstrap guide missing pack installation and test-environment wiring'
! rg -n -- '--lineup|N=1 \(default\)|report-only \(defaults\)|may just do it itself' \
  "$ROOT/README.md" "$ROOT/dev-pack/README.md" >/dev/null \
  || fail 'operator docs contain a stale flag, opinion default, or direct fallback'

printf 'workflow docs/default contract: ok\n'
