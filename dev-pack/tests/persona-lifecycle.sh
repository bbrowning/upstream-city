#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TOOL="$ROOT/dev-pack/assets/scripts/persona-lifecycle.py"
CORPUS="$ROOT/tools/vllm/personas"
PACK="$ROOT/dev-pack"
REGISTRY="$PACK/assets/persona-lenses.json"
COVERAGE="$ROOT/tools/vllm/eval/reflex-coverage.json"
CASES="$ROOT/tools/vllm/eval/cases"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

govern() {
  python3 "$TOOL" govern --corpus "${1:-$CORPUS}" --pack-root "$PACK" \
    --registry "${2:-$REGISTRY}" --coverage "${3:-$COVERAGE}" --cases "$CASES"
}

govern >/dev/null

python3 "$TOOL" select --corpus "$CORPUS" --lens design \
  --path vllm/parser/engine/parser_engine.py --path tests/parser/engine/test_parser_engine.py \
  >"$TMP/design"
grep -qx "$CORPUS/base.md" "$TMP/design" || fail "design omitted base"
grep -qx "$CORPUS/parser.md" "$TMP/design" || fail "design omitted matched parser persona"
! grep -q 'openai-frontend.md' "$TMP/design" || fail "design loaded irrelevant OpenAI persona"

python3 "$TOOL" select --corpus "$CORPUS" --lens change-review \
  --path vllm/entrypoints/openai/protocol.py >"$TMP/local-review"
grep -qx "$CORPUS/openai-frontend.md" "$TMP/local-review" \
  || fail "local review omitted matched OpenAI persona"
! grep -q '/parser.md' "$TMP/local-review" || fail "local review loaded irrelevant parser persona"

python3 "$TOOL" select --corpus "$CORPUS" --lens implementation \
  --path docs/unrelated.md >"$TMP/unrelated"
[ "$(wc -l <"$TMP/unrelated")" -eq 1 ] || fail "unrelated path loaded a domain persona"
grep -qx "$CORPUS/base.md" "$TMP/unrelated" || fail "unrelated path did not load base only"

cp "$REGISTRY" "$TMP/duplicate-lens.json"
python3 - "$TMP/duplicate-lens.json" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('{\n', '{\n  "design": {},\n', 1))
PY
if govern "$CORPUS" "$TMP/duplicate-lens.json" >"$TMP/duplicate.out" 2>&1; then
  fail "duplicate lens escaped governance"
fi
grep -q 'duplicate lens' "$TMP/duplicate.out" || fail "duplicate lens failed unclearly"

jq 'del(."base.1")' "$COVERAGE" >"$TMP/missing-coverage.json"
if govern "$CORPUS" "$REGISTRY" "$TMP/missing-coverage.json" >"$TMP/coverage.out" 2>&1; then
  fail "uncovered reflex escaped governance"
fi
grep -q 'reflex coverage mismatch' "$TMP/coverage.out" || fail "coverage failed unclearly"

cp -R "$CORPUS" "$TMP/personas"
cp "$CORPUS/parser.md" "$TMP/personas/parser-copy.md"
if govern "$TMP/personas" >"$TMP/duplicate-domain.out" 2>&1; then
  fail "duplicate persona activation escaped governance"
fi
grep -q 'duplicate activation domain' "$TMP/duplicate-domain.out" \
  || fail "duplicate persona failed unclearly"

printf 'persona lifecycle governance: ok\n'
