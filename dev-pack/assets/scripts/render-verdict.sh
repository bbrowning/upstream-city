#!/usr/bin/env bash
# render-verdict.sh — render a PR-review (pr-review.v1 / pr-review-quorum.v1),
# dynamic-check (pr-review-dynamic.v1), or divergence-settle (pr-review-settle.v1)
# verdict JSON as a human-readable, plaintext summary.
#
#   render-verdict.sh [<verdict.json> | -] [--bead <id>] [--run-url <url>] [--rig <name>]
#
# Reads the verdict JSON from the file argument, or from stdin when the argument
# is "-" or omitted. Schema is auto-detected by shape, the same way emit-verdict.sh
# does: `.resolutions` present -> settle; else `.verdict` present -> review; else
# -> dynamic check. Emits the summary to stdout. The footer (run link, full-JSON and
# re-read pointers) is included only when --bead / --run-url are supplied.
#
# This is the single source of truth for verdict -> human text: emit-verdict.sh
# uses it to build the notification mail body, and `gc dev-pack summary`
# uses it to re-render a stored verdict on demand — so both paths stay identical.
#
# The first output line is a single-line recap (no early newline) so the inbox's
# 60-char body preview (gc mail inbox) stays tidy; the subject remains the scan key.
set -euo pipefail

VF=""
BEAD=""
RUN_URL=""
RIG=""
BRIEF=""

die() { printf '%s\n' "render-verdict: $*" >&2; exit 2; }
usage() {
    printf '%s\n' \
        "usage: render-verdict.sh [<verdict.json> | -] [--bead <id>] [--run-url <url>] [--rig <name>] [--brief]" \
        "reads verdict JSON from the file arg or stdin ('-'); prints a human-readable summary" \
        "  --brief   compact per-finding digest (review verdicts only); default is the full view"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --bead)      BEAD="${2:?--bead needs a value}"; shift 2 ;;
        --bead=*)    BEAD="${1#*=}"; shift ;;
        --run-url)   RUN_URL="${2:?--run-url needs a value}"; shift 2 ;;
        --run-url=*) RUN_URL="${1#*=}"; shift ;;
        --rig)       RIG="${2:?--rig needs a value}"; shift 2 ;;
        --rig=*)     RIG="${1#*=}"; shift ;;
        --brief)     BRIEF=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        -)           VF="-"; shift ;;
        --)          shift ;;
        -*)          die "unknown option '$1'" ;;
        *)           if [ -z "$VF" ]; then VF="$1"; shift; else die "unexpected argument '$1'"; fi ;;
    esac
done

if [ -z "$VF" ] || [ "$VF" = "-" ]; then
    JSON=$(cat)
else
    [ -f "$VF" ] || die "verdict file not found: $VF"
    JSON=$(cat "$VF")
fi

printf '%s' "$JSON" | jq -e . >/dev/null 2>&1 || die "input is not valid JSON"

# The renderer, as a jq program. Kept in a quoted heredoc so its embedded single
# quotes (the approve-sling hint) survive; bead/run/rig arrive via --arg.
PROG=$(cat <<'JQ'
def nn: . != null and . != "";
def sevrank: (. // "") as $s | {"blocker":0,"major":1,"minor":2,"nit":3}[$s] // 9;
def shortmodel: sub("^.*/";"") | sub("^pr-reviewer-";"") | sub("-(xhigh|high|medium|low)$";"");
def shortverdict: sub("approve_with_nits";"approve-w/nits") | sub("request_changes";"request-changes");
def render_f:
  .n as $n | .f as $f |
  ["  \($n). [\($f.severity // "?")] \($f.title // "(untitled)")"]
  + (if ($f.file|nn) then ["     \($f.file)" + (if ($f.line|nn) then ":\($f.line)" else "" end)] else [] end)
  + (if ($f.suggested_fix|nn) then ["     -> \($f.suggested_fix)"] else [] end);
def footer($brief):
  (if (($bead|length) > 0) or (($run|length) > 0)
   then ["", "—"]
        + (if ($run|length) > 0 then ["run:     \($run)"] else [] end)
        + (if ($bead|length) > 0
           then ["verdict: gc bd show \($bead) --json   (full JSON)"]
                + (if $brief == "1"
                   then ["full:    gc dev-pack summary \($bead) --full"]
                   else ["re-read: gc dev-pack summary \($bead)"] end)
           else [] end)
   else [] end);

if (.resolutions != null) then
    (.head_ref // "?")                              as $head
  | (.settle_of // "")                             as $settle_of
  | (.settled_verdict // "")                        as $sv
  | (.summary // "")                               as $summary
  | (.disputes_examined // (.resolutions | length) // 0) as $dn
  | (.failure_class // "none")                     as $fclass
  | (.failure_reason // "")                        as $freason
  | ( .resolutions
      | map(.resolution)
      | { resolved: (map(select(. == "resolved")) | length),
          refuted: (map(select(. == "refuted")) | length),
          needs_dynamic: (map(select(. == "needs_dynamic")) | length),
          ambiguous: (map(select(. == "genuinely_ambiguous")) | length) } ) as $tally
  | (
      [ ( ["settle", "\($dn) dispute(s)",
           "\($tally.resolved) resolved · \($tally.refuted) refuted · \($tally.needs_dynamic) needs-check · \($tally.ambiguous) ambiguous"]
          | join(" · ") )
        + (if ($sv|length) > 0 then " · settled: \($sv)" else "" end),
        "",
        "## PR review settle — \($head)" ]
      + (if ($settle_of|length) > 0 then ["settling: \($settle_of)   disputes examined: \($dn)"] else ["disputes examined: \($dn)"] end)
      + (if $fclass != "none" then ["", "⚠ step \($fclass): \($freason)"] else [] end)
      + (if ($summary|length) > 0 then ["", "Summary", "  \($summary)"] else [] end)
      + ["", "Resolutions"]
      + (if ((.resolutions // []) | length) == 0
         then ["  (none)"]
         else ( .resolutions | to_entries | map(
                  (.key + 1) as $n | .value as $r |
                  [ "  \($n). [\($r.resolution // "?")] \($r.title // "(untitled)")"
                    + (if ($r.which_holds|nn) then " — holds: \($r.which_holds)" else "" end)
                    + (if ($r.severity|nn) then " · \($r.severity)" else "" end)
                    + (if ($r.confidence|nn) then " · confidence \($r.confidence)" else "" end) ]
                  + (if ($r.crux_question|nn) then ["     crux: \($r.crux_question)"] else [] end)
                  + (if ($r.rationale|nn) then ["     \($r.rationale)"] else [] end)
                  + (if (($r.evidence // []) | length) > 0
                     then ["     evidence:"] + ($r.evidence | map("       - " + ((.ref // "?")|tostring) + (if (.note|nn) then ": \(.note)" else "" end)))
                     else [] end)
                  + (if ($r.needs_dynamic != null) and (($r.needs_dynamic.command // "")|nn)
                     then ["     needs check (approve via pr-review-dynamic):",
                           "       \($r.needs_dynamic.command)"]
                     else [] end)
                ) | add )
         end)
      + footer("")
      | join("\n")
    )
elif (.verdict != null) then
    (.verdict // "?")                            as $v
  | (.effective_posture // .posture // "?")       as $posture
  | ((.findings_count) // (.findings | length) // 0) as $fc
  | (.merge_recommendation // "")                 as $mrec
  | (.summary // "")                              as $summary
  | (.head_ref // "?")                            as $head
  | (.failure_class // "none")                    as $fclass
  | (.failure_reason // "")                       as $freason
  | (
      ( if $brief == "1" then
          ( .findings // [] )                                   as $findings
        | ( .lanes // [] )                                      as $lanes
        | ( ["blocker","major","minor","nit"]
            | map( . as $s | ($findings | map(select((.severity // "") == $s)) | length) as $n
                           | if $n > 0 then "\($n) \($s)" else empty end )
            | join(" · ") )                                     as $tally
        | ( ($summary | capture("\\((?<d>[^()]{40,})\\)").d) // ($summary | split(". ")[0]) // "" ) as $ctx0
        | ( if ($ctx0|length) > 220 then ($ctx0[0:217] + "...") else $ctx0 end ) as $ctx
        | ( $lanes | map( ((.model // "?") | shortmodel) + " " + ((.verdict // "?") | shortverdict) ) | join(" vs ") ) as $lanestr
        | ( $findings | sort_by(.severity | sevrank) | to_entries
            | map( { n: (.key + 1), f: .value, rank: ((.value.severity // "") | sevrank) } ) ) as $sorted
        | ( $sorted | map(select(.rank <= 1)) )                 as $blockers
        | ( $sorted | map(select(.rank >= 2)) )                 as $nits
        | [ "PR \($head) · \($v | ascii_upcase | gsub("_"; " "))"
            + (if ($tally|length) > 0 then " · \($tally)" else "" end) ]
          + (if ($ctx|length) > 0 then [$ctx] else [] end)
          + (if ($lanes|length) > 0
             then ["Lanes: " + $lanestr
                   # pr-review-quorum.v1.evidence is an array.  A re-synthesis
                   # may optionally carry a top-level settle_bead marker, but
                   # indexing .evidence as an object makes ordinary quorum
                   # summaries fail with "Cannot index array with string".
                   + (if ((.settle_bead // "") != "") then " -> settled: \($v)" else "" end)]
             else [] end)
          + (if $fclass != "none" then ["", "⚠ step \($fclass): \($freason)"] else [] end)
          + (if ($sorted | length) == 0
             then ["", "no findings"]
             else (if ($blockers|length) > 0 then ["", "BLOCKERS - fix before merge"] + ($blockers | map(render_f) | add) else [] end)
                + (if ($nits|length) > 0 then ["", "NITS"] + ($nits | map(render_f) | add) else [] end)
             end)
          + (if (.dynamic_check == null) and (.dynamic_request != null) and
                 (((.dynamic_request.command // "")|nn) or ((.dynamic_request.checks // [])|length > 0))
             then ["", "suggested dynamic verification available (see --full)"] else [] end)
          + ( ( if (.dynamic_check != null)
                then "Dynamic verification: \(.dynamic_check.outcome // "?")"
                     + (if ((.dynamic_check.checks // [])|length) > 0 then " (\(.dynamic_check.checks|length) checks)" else "" end)
                     + (if (.dynamic_check.rc != null) then " (rc=\(.dynamic_check.rc))" else "" end)
                else null end ) as $dcline
              | ( (.read_only_enforcement // {}) as $roe
                  | if ($roe.clean == false) then "read-only: MUTATIONS DETECTED: \(($roe.mutations_delta // []) | join(", "))"
                    elif ($roe.clean == true) then "read-only: clean"
                    else null end ) as $roline
              | ( [$dcline, $roline] | map(select(. != null)) ) as $status
              | if ($status|length) > 0 then ["", ($status | join("   "))] else [] end )
        else
          [ ( [$v, $posture, "\($fc) finding(s)"] | join(" · ") )
            + (if ($mrec|length) > 0 then " · \($mrec)" else "" end),
            "",
            "## PR review — \($head)",
            "verdict: \($v)   posture: \($posture)   findings: \($fc)" ]
          + (if $fclass != "none" then ["", "⚠ step \($fclass): \($freason)"] else [] end)
          + (if ($summary|length) > 0 then ["", "Summary", "  \($summary)"] else [] end)
          + (if ($mrec|length) > 0 then ["", "Merge recommendation", "  \($mrec)"] else [] end)
          + ["", "Findings"]
          + (if ((.findings // []) | length) == 0
             then ["  (none)"]
             else ( .findings | to_entries | map(
                      (.key + 1) as $n | .value as $f |
                      [ "  \($n). [\($f.severity // "?")] \($f.title // "(untitled)")"
                        + (if ($f.file|nn)
                           then " — \($f.file)" + (if ($f.line|nn) then ":\($f.line)" else "" end)
                           else "" end) ]
                      + (if ($f.detail|nn) then ["     \($f.detail)"] else [] end)
                      + (if ($f.suggested_fix|nn) then ["     fix: \($f.suggested_fix)"] else [] end)
                    ) | add )
             end)
          + (if (.dynamic_check == null) and (.dynamic_request != null) and ((.dynamic_request.checks // [])|length > 0)
             then ["", "Suggested dynamic verification plan (needs your approval):",
                   "  \(.dynamic_request | tojson)",
                   "  approve: gc sling \(if ($rig|length) > 0 then $rig else "<rig>" end)/pr-runner pr-review-dynamic --formula --var head_ref=\($head) --var plan_json='\(.dynamic_request | tojson)'"]
             elif (.dynamic_check == null) and (.dynamic_request != null) and ((.dynamic_request.command // "")|nn)
             then ["", "Suggested check (needs your approval):",
                   "  \(.dynamic_request.command)",
                   "  approve: gc sling \(if ($rig|length) > 0 then $rig else "<rig>" end)/pr-runner pr-review-dynamic --formula --var head_ref=\($head) --var command='\(.dynamic_request.command)'"]
             else [] end)
          + ( ( if (.dynamic_check != null)
                then "Dynamic verification: \(.dynamic_check.outcome // "?")"
                     + (if ((.dynamic_check.checks // [])|length) > 0 then " (\(.dynamic_check.checks|length) checks)" else "" end)
                     + (if (.dynamic_check.rc != null) then " (rc=\(.dynamic_check.rc))" else "" end)
                else null end ) as $dcline
              | ( (.read_only_enforcement // {}) as $roe
                  | if ($roe.clean == false) then "read-only: MUTATIONS DETECTED: \(($roe.mutations_delta // []) | join(", "))"
                    elif ($roe.clean == true) then "read-only: clean"
                    else null end ) as $roline
              | ( [$dcline, $roline] | map(select(. != null)) ) as $status
              | if ($status|length) > 0 then ["", ($status | join("   "))] else [] end )
        end )
      + footer($brief)
      | join("\n")
    )
else
    (.outcome // "?")            as $oc
  | (.head_ref // "?")           as $head
  | (if ((.command // "")|length) > 0 then .command
     elif .plan != null then (.plan | tojson) else "?" end) as $cmd
  | (.rc)                        as $rc
  | (.ceiling_posture // "?")    as $ceil
  | (.summary // "")             as $summary
  | (.output_tail // "")         as $tail
  | (.failure_class // "none")   as $fclass
  | (.failure_reason // "")      as $freason
  | (
      [ ( ["dynamic verification \($oc)"]
          + (if ($rc != null) then ["rc=\($rc)"] else [] end)
          + ["\($head)"] | join(" · ") ),
        "",
        "## Dynamic verification — \($head)",
        "plan/command: \($cmd)",
        "outcome: \($oc)   rc: \(if ($rc != null) then ($rc|tostring) else "n/a" end)   ceiling: \($ceil)" ]
      + (if $fclass != "none" then ["", "⚠ step \($fclass): \($freason)"] else [] end)
      + (if ($summary|length) > 0 then ["", "Summary", "  \($summary)"] else [] end)
      + (if ($tail|length) > 0
         then ["", "Output (tail)"] + ($tail | rtrimstr("\n") | split("\n") | map("  " + .))
         else [] end)
      + (if ((.checks // [])|length) > 0
         then ["", "Checks"] + (.checks | map("  \(.purpose // "coverage") · \(.axis // "?") · \(.outcome // "?")"))
         else [] end)
      + (if (.git_clean_after == false) then ["", "read-only: MUTATIONS DETECTED: \((.mutations_delta // []) | join(", "))"]
         elif (.git_clean_after == true) then ["", "read-only: clean"]
         else [] end)
      + footer("")
      | join("\n")
    )
end
JQ
)

printf '%s\n' "$JSON" | jq -r --arg bead "$BEAD" --arg run "$RUN_URL" --arg rig "$RIG" --arg brief "$BRIEF" "$PROG"
