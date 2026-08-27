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
assert p['schema'] == 'dev-pack-workflow-policy.v1'
assert p['defaults']['local_only'] is True
assert p['defaults']['completion_checkpoint'] == 'approved'
assert p['presets']['quality']['feature'] == {'review_n': 2, 'formula': 'feature-dev'}
assert p['presets']['quality']['bug']['formula'] == 'hard-bug-round'
assert p['presets']['quality']['review'] == {'n': 2, 'formula': 'pr-review-quorum'}

formulas = root / 'dev-pack/formulas'
name = 'feature-dev.toml'
d = tomllib.loads((formulas/name).read_text())
assert int(d['vars']['review_n']['default']) == p['presets']['quality']['feature']['review_n'], name
assert int(d['vars']['max_review_iterations']['default']) == p['defaults']['max_review_iterations'], name
for name in ('hard-bug-finalize.toml', 'hard-bug-round.toml', 'hard-bug-round-solo.toml'):
    d = tomllib.loads((formulas/name).read_text())
    assert int(d['vars']['review_n']['default']) == p['presets']['quality']['bug']['review_n'], name
    assert int(d['vars']['max_review_iterations']['default']) == p['defaults']['max_review_iterations'], name
for name in ('hard-bug-finalize.toml', 'hard-bug-round.toml', 'hard-bug-round-solo.toml'):
    d = tomllib.loads((formulas/name).read_text())
    assert int(d['vars']['max_rounds']['default']) == p['defaults']['max_rounds'], name
for name in ('change-lifecycle.toml', 'change-lifecycle-solo.toml'):
    d = tomllib.loads((formulas/name).read_text())
    assert int(d['vars']['max_iterations']['default']) == p['defaults']['max_review_iterations'], name
PY

feature=$(GC_BIN=gc "$ROOT/dev-pack/commands/feature/run.sh" fixture-feature --rig fixture --dry-run)
bug=$(GC_BIN=gc "$ROOT/dev-pack/commands/bug/run.sh" fixture-bug --rig fixture --dry-run)
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
  jq -cn --arg path "$ROOT" '{rigs:[{name:"fixture",path:\$path}]}'
elif [[ "\$args" == *" agent list "* ]]; then
  printf '%s\n' fixture/pr-review-synthesizer fixture/pr-reviewer-sonnet-xhigh fixture/pr-reviewer-gpt56luna-xhigh
else
  exit 99
fi
GC
chmod +x "$TMP/gc"
review=$(GC_BIN="$TMP/gc" GC_CITY_PATH="$ROOT" "$ROOT/dev-pack/commands/review/run.sh" 123 --rig fixture --dry-run)
for expected in 'preset=quality' 'n=2' 'pr-review-quorum --formula' 'completion=human_checkpoint'; do
  printf '%s' "$review" | grep -q "$expected" || fail "review dry-run drift: $expected"
done

# Every accepted workflow flag must be visible in the supported pack-command help.
for spec in \
  'feature:--quality --fast --solo --review-n --review-lanes --max-review-iterations --dry-run' \
  'bug:--quality --fast --solo --report-only --n --loop --max-rounds --review-n --review-lanes --dry-run' \
  'review:--quality --fast --solo --n --lanes --artifact --dry-run'; do
  command=${spec%%:*}; flags=${spec#*:}
  help=$(gc dev-pack "$command" --help)
  for flag in $flags; do
    printf '%s' "$help" | grep -q -- "$flag" || fail "$command help hides $flag"
    grep -q -- "$flag" "$ROOT/dev-pack/commands/$command/run.sh" || fail "$command parser lacks documented $flag"
  done
done

docs=$(printf '%s\n' "$ROOT/README.md" "$ROOT/dev-pack/README.md")
for phrase in 'Implement this feature' 'Fix this bug' 'Review PR N'; do
  grep -q "$phrase" $docs || fail "quickstart missing human request: $phrase"
done
for phrase in 'N=2 independent review' 'strict synthesis' 'evidence settlement' \
  'maximum 3 revisions' 'branch + exact HEAD SHA' 'gc.lead_escalation_json' \
  'Copy-paste verification' 'local-only'; do
  grep -q "$phrase" "$ROOT/dev-pack/README.md" || fail "canonical guide missing lifecycle contract: $phrase"
done
! rg -n -- '--lineup|N=1 \(default\)|report-only \(defaults\)|may just do it itself' \
  "$ROOT/README.md" "$ROOT/dev-pack/README.md" >/dev/null \
  || fail 'operator docs contain a stale flag, opinion default, or direct fallback'

printf 'workflow docs/default contract: ok\n'
