#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat > "$TMP/gc" <<'GC'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GC_TEST_LOG:?}"
args=" $* "

if [[ "$args" == *" rig list --json "* ]]; then
    printf '%s\n' '{"rigs":[{"name":"vllm","path":"/tmp/vllm"}]}'
elif [[ "$args" == *" bd list "* && "$args" == *"gc.followup_of="* ]]; then
    printf '%s\n' '[]'
elif [[ "$args" == *" bd list "* ]]; then
    # The resolver must not use the eventually-consistent metadata index.
    [[ "$args" != *" --metadata-field "* ]] || exit 91
    jq -cn '
      def verdict($head; $verdict; $count; $summary):
        {head_ref:$head, base_ref:"origin/main", verdict:$verdict,
         posture:"trusted", effective_posture:"trusted",
         findings_count:$count, findings:[], summary:$summary,
         merge_recommendation:"test recommendation"} | tojson;
      def bead($id; $logical; $ts; $reason; $schema; $lane; $role; $json):
        {id:$id, closed_at:$ts, close_reason:$reason,
         metadata: ({"gc.output_json_schema":$schema,"gc.output_json":$json}
                    + (if $logical == null then {} else {"gc.logical_bead_id":$logical} end)
                    + (if $lane == null then {} else {"gc.review_quorum_lane":$lane} end)
                    + (if $role == null then {} else {"gc.review_quorum_role":$role} end))};
      [
        # Quorum: logical/work mirrors plus a lane retry newer than synthesis.
        bead("vllm-lane-logical"; null; "2026-08-26T00:01:00Z"; null; "pr-review.v1"; "reviewer-a"; null;
             verdict("70001"; "approve_with_nits"; 2; "partial lane")),
        bead("vllm-lane-work"; "vllm-lane-logical"; "2026-08-26T00:09:00Z"; "review: approve_with_nits (2 findings)"; "pr-review.v1"; "reviewer-a"; null;
             verdict("70001"; "approve_with_nits"; 2; "partial lane")),
        bead("vllm-synth-logical"; null; "2026-08-26T00:08:00Z"; null; "pr-review-quorum.v1"; null; "synthesis";
             verdict("70001"; "request_changes"; 5; "authoritative quorum")),
        bead("vllm-synth-work"; "vllm-synth-logical"; "2026-08-26T00:07:00Z"; "review: request_changes (5 findings)"; "pr-review-quorum.v1"; null; "synthesis";
             verdict("70001"; "request_changes"; 5; "authoritative quorum")),

        # Genuine N=1: no quorum lane marker, with the emitted work bead older
        # than its logical mirror to prove the pair is collapsed canonically.
        bead("vllm-solo-logical"; null; "2026-08-26T00:12:00Z"; null; "pr-review.v1"; null; null;
             verdict("70002"; "approve"; 0; "solo logical mirror")),
        bead("vllm-solo-work"; "vllm-solo-logical"; "2026-08-26T00:11:00Z"; "review: approve (0 findings)"; "pr-review.v1"; null; null;
             verdict("70002"; "approve"; 0; "genuine solo verdict")),

        # An incomplete quorum must never degrade to a partial lane.
        bead("vllm-only-lane"; null; "2026-08-26T00:20:00Z"; "review: approve (0 findings)"; "pr-review.v1"; "reviewer-a"; null;
             verdict("70003"; "approve"; 0; "incomplete lane")),

        # Role is an independent synthesis discriminator for older producers.
        bead("vllm-role-lane"; null; "2026-08-26T00:31:00Z"; "review: approve (0 findings)"; "pr-review.v1"; "reviewer-a"; null;
             verdict("70004"; "approve"; 0; "role test lane")),
        bead("vllm-role-work"; null; "2026-08-26T00:30:00Z"; "review: request_changes (1 findings)"; "pr-review.v1"; null; "synthesis";
             verdict("70004"; "request_changes"; 1; "role-marked synthesis"))
      ]'
elif [[ "$args" == *" bd show vllm-synth-work --json "* ]]; then
    jq -cn '[{id:"vllm-synth-work",metadata:{"gc.root_bead_id":"vllm-run","gc.output_json_schema":"pr-review-quorum.v1","gc.output_json":({head_ref:"70001",base_ref:"origin/main",verdict:"request_changes",posture:"trusted",effective_posture:"trusted",findings_count:5,findings:[],summary:"authoritative quorum",merge_recommendation:"test recommendation"}|tojson)}}]'
elif [[ "$args" == *" bd show vllm-solo-work --json "* ]]; then
    jq -cn '[{id:"vllm-solo-work",metadata:{"gc.output_json_schema":"pr-review.v1","gc.output_json":({head_ref:"70002",base_ref:"origin/main",verdict:"approve",findings_count:0,findings:[],summary:"genuine solo verdict"}|tojson)}}]'
else
    printf 'unexpected gc call: %s\n' "$*" >&2
    exit 99
fi
GC
chmod +x "$TMP/gc"

export GC_BIN="$TMP/gc"
export GC_CITY_PATH="$ROOT"
export GC_TEST_LOG="$TMP/gc.log"
: > "$GC_TEST_LOG"

RESOLVE="$ROOT/dev-pack/assets/scripts/resolve-verdict-bead.sh"

[ "$($RESOLVE 70001 --rig vllm 2>/dev/null)" = vllm-synth-work ] \
    || fail 'quorum did not resolve to the emitted synthesis bead'
[ "$($RESOLVE 70002 --rig vllm 2>/dev/null)" = vllm-solo-work ] \
    || fail 'genuine N=1 review did not resolve to its emitted work bead'
[ "$($RESOLVE 70004 --rig vllm 2>/dev/null)" = vllm-role-work ] \
    || fail 'role-marked synthesis was not authoritative'

if incomplete=$($RESOLVE 70003 --rig vllm 2>&1); then
    fail 'lane-only quorum snapshot unexpectedly resolved'
fi
[[ "$incomplete" == *'reviewer-lane verdicts'* ]] \
    || fail "lane-only failure lacked synthesis guidance: $incomplete"

summary_out=$("$ROOT/dev-pack/commands/summary/run.sh" 70001 --rig vllm --full 2>&1)
[[ "$summary_out" == *'vllm-synth-work'* && "$summary_out" == *'request_changes'* \
   && "$summary_out" == *'authoritative quorum'* ]] \
    || fail "summary did not render the synthesis verdict: $summary_out"

ask_out=$("$ROOT/dev-pack/commands/ask/run.sh" 70001 'why?' --rig vllm --dry-run 2>&1)
[[ "$ask_out" == *'root verdict bead vllm-synth-work'* \
   && "$ask_out" == *'materialize/run.sh 70001 --rig vllm'* ]] \
    || fail "ask did not ground itself in the synthesis verdict: $ask_out"

! grep -q 'gc.output_json_schema=' "$GC_TEST_LOG" \
    || fail "resolver used the eventually-consistent metadata index: $(cat "$GC_TEST_LOG")"

printf '%s\n' 'ok: dev-pack authoritative verdict resolution'
