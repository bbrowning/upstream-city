#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
UPDATE="$ROOT/dev-pack/assets/scripts/update-work-lifecycle.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP/bin"
printf '%s\n' '{"status":"open","metadata":{}}' >"$TMP/state.json"
: >"$TMP/gc.log"
cat >"$TMP/bin/gc" <<'GC'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_GC_LOG:?}"
while [ $# -gt 0 ]; do
  case "$1" in --city|--rig) shift 2 ;; *) break ;; esac
done
case "${1-} ${2-}" in
  "bd show") jq -c '[.]' "${MOCK_GC_STATE:?}" ;;
  "bd update")
    shift 3
    next="${MOCK_GC_STATE}.next"; cp "${MOCK_GC_STATE}" "$next"
    while [ $# -gt 0 ]; do
      case "$1" in
        --set-metadata)
          pair=$2; key=${pair%%=*}; value=${pair#*=}
          jq --arg key "$key" --arg value "$value" '.metadata[$key]=$value' "$next" >"$next.tmp"
          mv "$next.tmp" "$next"; shift 2 ;;
        --status)
          jq --arg status "$2" '.status=$status' "$next" >"$next.tmp"
          mv "$next.tmp" "$next"; shift 2 ;;
        *) shift ;;
      esac
    done
    mv "$next" "${MOCK_GC_STATE}" ;;
  "bd close")
    jq '.status="closed"' "${MOCK_GC_STATE}" >"${MOCK_GC_STATE}.next"
    mv "${MOCK_GC_STATE}.next" "${MOCK_GC_STATE}" ;;
  *) printf 'unexpected gc call: %s\n' "$*" >&2; exit 99 ;;
esac
GC
chmod +x "$TMP/bin/gc"
export GC_BIN="$TMP/bin/gc" MOCK_GC_LOG="$TMP/gc.log" MOCK_GC_STATE="$TMP/state.json"

for contract in "$ROOT/dev-pack/formulas/feature-dev.toml" \
  "$ROOT/dev-pack/formulas/hard-bug-finalize.toml" \
  "$ROOT/dev-pack/formulas/change-lifecycle.toml" \
  "$ROOT/dev-pack/assets/scripts/decide-change-lifecycle.sh"; do
  grep -Eq 'update-work-lifecycle.sh|sling-change-lifecycle.sh|decide-change-lifecycle.sh' "$contract" \
    || fail "shared lifecycle contract missing from $contract"
done

update() { "$UPDATE" --bead work-1 --intent feature "$@"; }

update --checkpoint implementation --disposition awaiting_review --iteration 1 \
  --artifact-id artifact-1 --head-sha head-1 --branch feature/work-1
! grep -q 'bd close work-1' "$TMP/gc.log" || fail "implementation closed parent work"

update --checkpoint review --disposition request_changes --iteration 1 \
  --artifact-id artifact-1 --head-sha head-1 --branch feature/work-1 \
  --feedback-bead review-1 --reason changes-requested
! grep -q 'bd close work-1' "$TMP/gc.log" || fail "request_changes closed parent work"

update --checkpoint review --disposition blocked --iteration 2 \
  --artifact-id artifact-2 --head-sha head-2 --branch feature/work-1 \
  --feedback-bead review-2 --reason reviewer-unavailable
! grep -q 'bd close work-1' "$TMP/gc.log" || fail "blocked outcome closed parent work"
jq -e '.status == "in_progress" and (.metadata["gc.lifecycle_json"] | fromjson |
  .schema == "work-lifecycle.v1" and .disposition == "blocked" and .reason == "reviewer-unavailable")' \
  "$TMP/state.json" >/dev/null || fail "blocked lifecycle state was not durable"

update --checkpoint review --disposition approved --iteration 3 \
  --artifact-id artifact-3 --head-sha head-3 --branch feature/work-1 \
  --feedback-bead review-3 --reason approved
[ "$(grep -c 'bd close work-1' "$TMP/gc.log")" -eq 1 ] || fail "approval did not close exactly once"

# Replaying the same terminal checkpoint is an idempotent no-op.
update --checkpoint review --disposition approved --iteration 3 \
  --artifact-id artifact-3 --head-sha head-3 --branch feature/work-1 \
  --feedback-bead review-3 --reason approved
[ "$(grep -c 'bd close work-1' "$TMP/gc.log")" -eq 1 ] || fail "terminal replay closed twice"
jq -e '.status == "closed" and (.metadata["gc.lifecycle_json"] | fromjson |
  .disposition == "approved" and .artifact_id == "artifact-3" and .head_sha == "head-3")' \
  "$TMP/state.json" >/dev/null || fail "approved terminal state missing"

printf 'work lifecycle closure: ok\n'
