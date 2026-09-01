#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ENSURE="$ROOT/dev-pack/assets/scripts/ensure-review-source.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/city/.gc" "$TMP/state"
printf '%s\n' '[]' > "$TMP/state/beads.json"

cat > "$TMP/gc" <<'GC'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
if [[ "$args" == *" bd list "* ]]; then
  cat "${SOURCE_STATE:?}/beads.json"
elif [[ "$args" == *" bd create "* ]]; then
  id=vllm-human-48200
  jq -cn --arg id "$id" '[{id:$id,external_ref:"gh-48200",issue_type:"task",status:"open",labels:["human-facing","attention"],metadata:{"gc.human_source":"github-review.v1"}}]' > "$SOURCE_STATE/beads.json"
  printf '%s\n' "$id"
else
  printf 'unexpected gc call: %s\n' "$*" >&2; exit 99
fi
GC
chmod +x "$TMP/gc"
export GC_BIN="$TMP/gc" GC_CITY_PATH="$TMP/city" SOURCE_STATE="$TMP/state"

first=$("$ENSURE" --rig vllm --pr 48200)
second=$("$ENSURE" --rig vllm --pr 48200)
[ "$first" = vllm-human-48200 ] && [ "$second" = "$first" ]
[ "$(jq length "$TMP/state/beads.json")" -eq 1 ]

jq '. + [{id:"vllm-duplicate",external_ref:"gh-48200",labels:["human-facing"]}]' \
  "$TMP/state/beads.json" > "$TMP/state/duplicate.json"
mv "$TMP/state/duplicate.json" "$TMP/state/beads.json"
if "$ENSURE" --rig vllm --pr 48200 >"$TMP/out" 2>&1; then
  echo 'duplicate sources unexpectedly accepted' >&2; exit 1
fi
grep -Fq 'reconcile duplicates before dispatch' "$TMP/out"

echo 'review-human-source: ok'
