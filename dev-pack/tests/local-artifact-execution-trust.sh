#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
EMIT="$ROOT/dev-pack/assets/scripts/emit-local-change.sh"
RESOLVE="$ROOT/dev-pack/assets/scripts/resolve-local-change.sh"
PRESCAN="$ROOT/dev-pack/assets/scripts/pr-prescan.sh"
LATITUDE="$ROOT/dev-pack/assets/scripts/posture-latitude.sh"
RUN_CHECK="$ROOT/dev-pack/assets/scripts/run-scoped-check.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

git init -q -b main "$TMP/repo"
git -C "$TMP/repo" config user.name Test
git -C "$TMP/repo" config user.email test@example.invalid
printf 'base\n' >"$TMP/repo/app.py"
git -C "$TMP/repo" add app.py
git -C "$TMP/repo" commit -qm base

# A content-derived limited cap must not suppress a check for a canonical
# internally produced artifact. The subprocess token deliberately creates the cap.
git -C "$TMP/repo" switch -qc feature/internal
mkdir -p "$TMP/repo/tests"
cat >"$TMP/repo/tests/check_dynamic.py" <<'PY'
import subprocess  # prescan: conservative dynamic-exec signal

print(subprocess.DEVNULL)
PY
git -C "$TMP/repo" add tests/check_dynamic.py
git -C "$TMP/repo" commit -qm 'Add internal review fixture' \
  -m 'Exercise provenance-gated execution at a limited ceiling.'
printf '[]\n' >"$TMP/checks.json"
"$EMIT" --repo "$TMP/repo" --rig paude --workflow feature-dev --bead fixture-work \
  --intent feature --base main --branch feature/internal --verification-file "$TMP/checks.json" \
  --revision 1 --output "$TMP/internal.json"

INTERNAL_ID=$(jq -r .artifact_id "$TMP/internal.json")
INTERNAL_HEAD=$(jq -r .head.sha "$TMP/internal.json")
BASE_SHA=$(jq -r .base.sha "$TMP/internal.json")
scan=$(cd "$TMP/repo" && GC_RIG=paude "$PRESCAN" "$INTERNAL_HEAD" "$BASE_SHA")
jq -e '.ceiling_posture == "limited" and .facts.pattern_hits.subprocess > 0' <<<"$scan" >/dev/null \
  || fail "fixture did not retain its content-derived limited cap"
# A canonical restricted artifact stays fail-closed even with producer provenance.
git -C "$TMP/repo" switch -q main
git -C "$TMP/repo" switch -qc feature/restricted
mkdir -p "$TMP/repo/tests"
git -C "$TMP/repo" show feature/internal:tests/check_dynamic.py >"$TMP/repo/tests/check_dynamic.py"
printf 'raise RuntimeError("must not import")\n' >"$TMP/repo/sitecustomize.py"
git -C "$TMP/repo" add sitecustomize.py tests/check_dynamic.py
git -C "$TMP/repo" commit -qm 'Add restricted review fixture' \
  -m 'Exercise the startup-hook execution denial for internal artifacts.'
"$EMIT" --repo "$TMP/repo" --rig paude --workflow feature-dev --bead fixture-risk \
  --intent feature --base main --branch feature/restricted --verification-file "$TMP/checks.json" \
  --revision 1 --output "$TMP/restricted.json"
RESTRICTED_ID=$(jq -r .artifact_id "$TMP/restricted.json")
RESTRICTED_HEAD=$(jq -r .head.sha "$TMP/restricted.json")

mkdir -p "$TMP/bin" "$TMP/venv/bin"
ln -s "$(command -v python3)" "$TMP/venv/bin/python"
cat >"$TMP/bin/gc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [ $# -gt 0 ]; do
  case "$1" in --city|--rig) shift 2 ;; *) break ;; esac
done
[ "${1-} ${2-}" != "rig list" ] || { jq -cn '{rigs:[{name:"paude",path:"/unused"}]}'; exit; }
[ "${1-} ${2-}" = "bd show" ] || exit 2
case "${3-}" in
  fixture-work)
    lifecycle=$(jq -cn --arg id "$INTERNAL_ID" --arg head "$INTERNAL_HEAD" \
      '{schema:"work-lifecycle.v1",intent_kind:"feature",checkpoint:"implementation",disposition:"awaiting_review",iteration:1,artifact_id:$id,head_sha:$head,branch:"feature/internal"}') ;;
  fixture-risk)
    lifecycle=$(jq -cn --arg id "$RESTRICTED_ID" --arg head "$RESTRICTED_HEAD" \
      '{schema:"work-lifecycle.v1",intent_kind:"feature",checkpoint:"implementation",disposition:"awaiting_review",iteration:1,artifact_id:$id,head_sha:$head,branch:"feature/restricted"}') ;;
  *) exit 2 ;;
esac
jq -cn --arg lifecycle "$lifecycle" '[{metadata:{"gc.lifecycle_json":$lifecycle}}]'
EOF
chmod +x "$TMP/bin/gc"

export INTERNAL_ID INTERNAL_HEAD RESTRICTED_ID RESTRICTED_HEAD
GC_BIN="$TMP/bin/gc" GC_CITY_PATH="$TMP" \
  "$RESOLVE" --repo "$TMP/repo" --rig paude --artifact "$TMP/internal.json" \
    --require-internal-producer >/dev/null || fail "canonical producer was not trusted"

# Integrity alone is not producer provenance: a recomputed forged artifact must
# not gain latitude when no lifecycle bead binds that exact artifact/range.
jq '.producer.bead="forged-work" | del(.artifact_id)' "$TMP/internal.json" >"$TMP/forged-body.json"
FORGED_BODY=$(jq -S -c . "$TMP/forged-body.json")
FORGED_ID=$(printf '%s' "$FORGED_BODY" | sha256sum | awk '{print $1}')
jq -S -c --arg id "$FORGED_ID" '. + {artifact_id:$id}' "$TMP/forged-body.json" >"$TMP/forged.json"
if GC_BIN="$TMP/bin/gc" GC_CITY_PATH="$TMP" \
  "$RESOLVE" --repo "$TMP/repo" --rig paude --artifact "$TMP/forged.json" \
    --require-internal-producer >"$TMP/forged.out" 2>&1; then
  fail "forged artifact gained internal-producer trust"
fi
grep -q 'producer lifecycle bead' "$TMP/forged.out" || { cat "$TMP/forged.out" >&2; fail "forgery denial was unclear"; }

eval "$("$LATITUDE" limited external)"
[ "$EXEC $GATE" = "deny human" ] || fail "external limited posture was widened"
eval "$("$LATITUDE" limited internal-producer)"
[ "$EXEC $GATE" = "allow none" ] || fail "eligible internal limited artifact stayed denied"
eval "$("$LATITUDE" trusted internal-producer)"
[ "$FETCH $EXEC $GATE" = "allowlist allow none" ] \
  || fail "trusted internal artifact lost its sandboxed fetch/execution latitude"
for posture in restricted block; do
  eval "$("$LATITUDE" "$posture" internal-producer)"
  [ "$EXEC" = deny ] || fail "$posture internal artifact gained execution"
done

# The dynamic gate must independently validate producer provenance, preserve the
# limited content ceiling, and pin the exact head.
git -C "$TMP/repo" switch -q feature/internal
result=$(cd "$TMP/repo" && GC_BIN="$TMP/bin/gc" GC_CITY_PATH="$TMP" GC_RIG=paude \
  GC_PR_TEST_VENV="$TMP/venv" \
  "$RUN_CHECK" --head "$INTERNAL_HEAD" --base "$BASE_SHA" --min-ceiling limited \
    --internal-artifact "$TMP/internal.json" --expect-head-sha "$INTERNAL_HEAD" \
    -- python tests/check_dynamic.py)
jq -e '.outcome == "pass" and .ran == true and .ceiling == "limited" and
  .execution_authority == "internal-producer"' <<<"$result" >/dev/null \
  || fail "internal artifact check did not run"

git -C "$TMP/repo" switch -q feature/restricted
restricted=$(cd "$TMP/repo" && GC_BIN="$TMP/bin/gc" GC_CITY_PATH="$TMP" GC_RIG=paude \
  GC_PR_TEST_VENV="$TMP/venv" \
  "$RUN_CHECK" --head "$RESTRICTED_HEAD" --base "$BASE_SHA" --min-ceiling limited \
    --internal-artifact "$TMP/restricted.json" --expect-head-sha "$RESTRICTED_HEAD" \
    -- python tests/check_dynamic.py)
jq -e '.outcome == "skipped" and .ran == false and
  (.reason_if_skipped | contains("ceiling-below-required"))' <<<"$restricted" >/dev/null \
  || fail "restricted internal artifact did not fail closed"

# Existing branch-drift validation remains part of the trusted path.
git -C "$TMP/repo" switch -q main
git -C "$TMP/repo" branch -f feature/internal "$BASE_SHA"
if GC_BIN="$TMP/bin/gc" GC_CITY_PATH="$TMP" \
  "$RESOLVE" --repo "$TMP/repo" --rig paude --artifact "$TMP/internal.json" \
    --require-internal-producer >"$TMP/drift.out" 2>&1; then
  fail "drifting artifact gained internal-producer trust"
fi
grep -q 'stale artifact' "$TMP/drift.out" || fail "drift denial was unclear"

printf 'local artifact execution trust: ok\n'
