#!/usr/bin/env bash
# Resolve the one canonical human-facing bead for a routine GitHub PR review.
# This is the only intentional bead mutation in review launch. It does not read
# or modify mail and never writes GitHub.
set -euo pipefail

GC="${GC_BIN:-gc}"
CITY="${GC_CITY_PATH:-${GC_CITY:-$PWD}}"
RIG=""
PR=""

die() { printf '%s\n' "ensure-review-source: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --rig) RIG="${2:?--rig needs a value}"; shift 2 ;;
        --pr) PR="${2:?--pr needs a value}"; shift 2 ;;
        *) die "unknown argument '$1'" ;;
    esac
done
[ -n "$RIG" ] && [[ "$PR" =~ ^[0-9]+$ ]] || die "usage: ensure-review-source.sh --rig RIG --pr NUMBER"

lock_dir="$CITY/.gc/locks/dev-pack-review-source"
mkdir -p "$lock_dir"
exec 9>"$lock_dir/$RIG-gh-$PR.lock"
flock 9

external="gh-$PR"
list=$($GC --city "$CITY" --rig "$RIG" bd list --all --limit 0 --json --flat)
matches=$(printf '%s' "$list" | jq -c --arg ref "$external" \
  '[.[] | select(.external_ref == $ref) | select(
    ((.labels // []) | map(ascii_downcase) | any(. == "human-facing" or . == "attention" or . == "attention=true" or . == "maintainer")) and
    (((.labels // []) | map(ascii_downcase) | index("human-facing=false")) == null) and
    (((.labels // []) | map(ascii_downcase) | index("attention=false")) == null)
  )]') || die "could not inspect source beads"
count=$(printf '%s' "$matches" | jq -r 'length')
case "$count" in
    0)
        $GC --city "$CITY" --rig "$RIG" bd create "Human disposition for GitHub PR #$PR" \
          --type task --priority 1 --external-ref "$external" \
          --labels human-facing,attention,github-review \
          --description "Canonical human-facing disposition for routine review of GitHub PR #$PR. Automation evidence is linked here; record approval, changes requested, defer, or close on this bead." \
          --metadata '{"gc.human_source":"github-review.v1"}' --silent
        ;;
    1) printf '%s\n' "$matches" | jq -r '.[0].id' ;;
    *)
        ids=$(printf '%s' "$matches" | jq -r 'map(.id) | join(", ")')
        die "external ref $external has $count human-facing source beads ($ids); reconcile duplicates before dispatch"
        ;;
esac
