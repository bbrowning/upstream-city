#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CLAIM="$ROOT/dev-pack/assets/scripts/claim-trigger.sh"
EMIT="$ROOT/dev-pack/assets/scripts/emit-review.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/work" "$TMP/runtime"
printf '%s\n' running >"$TMP/state/runtime"
printf '%s\n' lane-a >"$TMP/state/active"
printf '%s\n' lane-b >"$TMP/state/pending"
for bead in lane-a lane-b; do
  jq -cn --arg id "$bead" \
    '{id:$id,status:"open",assignee:null,metadata:{"gc.routed_to":"rig/reviewer"}}' \
    >"$TMP/state/$bead.json"
done

cat >"$TMP/bin/gc" <<'GC'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${MOCK_STATE:?}
printf '%s\t%s\t%s\t%s\n' "${GC_SESSION_NAME:-}" "${GC_TRIGGER_BEAD_ID:-}" "${GC_AGENT:-}" "$*" >>"${MOCK_LOG:?}"

if [ "${1-}" = --city ] && [ "${3-} ${4-} ${5-}" = "rig list --json" ]; then
  printf '%s\n' '{"rigs":[{"name":"rig"}]}'
  exit 0
fi

case "${1-} ${2-}" in
  'bd show')
    bead=${3:?}
    jq -s . "$state_dir/$bead.json"
    ;;
  'bd update')
    bead=${3:?}; shift 3
    file="$state_dir/$bead.json"
    value=$(cat "$file")
    while [ $# -gt 0 ]; do
      case "$1" in
        --claim)
          [ "$(printf '%s' "$value" | jq -r .status)" = open ] || exit 4
          value=$(printf '%s' "$value" | jq --arg owner "${GC_SESSION_NAME:-}" \
            '.status="in_progress" | .assignee=$owner')
          shift
          ;;
        --set-metadata)
          pair=$2; key=${pair%%=*}; datum=${pair#*=}
          value=$(printf '%s' "$value" | jq --arg key "$key" --arg datum "$datum" \
            '.metadata[$key]=$datum')
          shift 2
          ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$value" >"$file.next"; mv "$file.next" "$file"
    ;;
  'bd close')
    bead=${3:?}; file="$state_dir/$bead.json"
    jq '.status="closed"' "$file" >"$file.next"; mv "$file.next" "$file"
    ;;
  'runtime drain')
    printf '%s\n' draining >"$state_dir/runtime"
    ;;
  'runtime drain-ack')
    [ "$(cat "$state_dir/runtime")" = draining ] || exit 5
    active=$(cat "$state_dir/active")
    [ "$(jq -r .status "$state_dir/$active.json")" = closed ] || exit 6
    printf '%s\n' stopped >"$state_dir/runtime"
    if [ -s "$state_dir/pending" ]; then
      next=$(sed -n '1p' "$state_dir/pending")
      sed '1d' "$state_dir/pending" >"$state_dir/pending.next"
      mv "$state_dir/pending.next" "$state_dir/pending"
      printf '%s\n' "$next" >"$state_dir/active"
      printf '%s\n' running >"$state_dir/runtime"
    else
      : >"$state_dir/active"
    fi
    ;;
  'mail send') printf '%s\n' '{"id":"mail"}' ;;
  *) printf 'unexpected gc call: %s\n' "$*" >&2; exit 99 ;;
esac
GC
chmod +x "$TMP/bin/gc"

export GC_BIN="$TMP/bin/gc" GC_CITY_PATH="$ROOT" GC_CITY_RUNTIME_DIR="$TMP/runtime"
export GC_RIG=rig GC_SESSION_ORIGIN=ephemeral GC_PR_NOTIFY_TO=''
export MOCK_STATE="$TMP/state" MOCK_LOG="$TMP/gc.log"

review=$(jq -cn '{schema:"pr-review.v1",head_ref:"feature/safe",base_ref:"main",
  implementation_provenance:null,verdict:"approve",posture:"trusted",effective_posture:"trusted",
  ceiling_posture:"trusted",summary:"ready",merge_recommendation:"merge",findings_count:0,
  findings:[],dynamic_check:"not_needed",dynamic_request:null,evidence:[],
  read_only_enforcement:{clean:true,mutations_delta:[]},failure_class:"none",failure_reason:""}')

run_assignment() {
  local expected=$1 session=$2
  local trigger
  trigger=$(cat "$TMP/state/active")
  [ "$trigger" = "$expected" ] || fail "expected active trigger $expected, got $trigger"
  (
    cd "$TMP/work"
    GC_TRIGGER_BEAD_ID="$trigger" GC_AGENT=rig/reviewer-1 GC_SESSION_NAME="$session" \
      "$CLAIM" >/dev/null
    printf '%s\n' "$review" | \
      GC_TRIGGER_BEAD_ID="$trigger" GC_AGENT=rig/reviewer-1 GC_SESSION_NAME="$session" \
      python3 "$EMIT" --bead "$trigger" --schema pr-review.v1 --outcome pass
  )
}

# A single-slot pool starts lane A, retires it completely after terminal close,
# then allocates lane B to a fresh session. The second claim is bound only to the
# new launch trigger; a stale lane-A trigger would fail closed in claim-trigger.sh.
run_assignment lane-a pool-session-1
[ "$(cat "$TMP/state/active")" = lane-b ] || fail 'lane B did not advance after lane A drain acknowledgment'
run_assignment lane-b pool-session-2
[ ! -s "$TMP/state/active" ] || fail 'pool still has an active trigger after both assignments'
[ "$(cat "$TMP/state/runtime")" = stopped ] || fail 'terminal worker retained the max=1 pool slot'

[ "$(grep -c $'pool-session-1\tlane-a\t.*\tbd update lane-a --claim' "$TMP/gc.log")" -eq 1 ] \
  || fail 'first session did not claim exactly lane A'
[ "$(grep -c $'pool-session-2\tlane-b\t.*\tbd update lane-b --claim' "$TMP/gc.log")" -eq 1 ] \
  || fail 'fresh second session did not claim exactly lane B'
! grep -q $'pool-session-2\tlane-a\t.*\tbd update .* --claim' "$TMP/gc.log" \
  || fail 'second session retried the stale closed lane-A trigger'
[ "$(grep -c $'runtime drain rig/reviewer-1' "$TMP/gc.log")" -eq 2 ] \
  || fail 'terminal emitters did not request both drains'
[ "$(grep -c $'runtime drain-ack rig/reviewer-1' "$TMP/gc.log")" -eq 2 ] \
  || fail 'terminal emitters did not release both pool slots'

printf '%s\n' 'max=1 pool forward progress: ok'
