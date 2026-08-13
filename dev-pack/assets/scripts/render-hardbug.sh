#!/usr/bin/env bash
# render-hardbug.sh — render a hard-bug reconcile (hard-bug-reconcile.v1) or final
# (hard-bug-final.v1) object as a human-readable, plaintext mail body. The bug-lane
# sibling of render-verdict.sh: humans read prose, not JSON.
#
#   render-hardbug.sh [<hardbug.json> | -]
#
# Reads the JSON from the file argument, or from stdin when the argument is "-" or
# omitted. Schema is auto-detected by field presence (these objects carry no inline
# `schema` field): `.aligned` present -> reconcile; `.concurred`/`.branch` present ->
# final; anything else -> a safe generic dump. Emits the summary to stdout.
#
# Wired in via emit-json.sh's `--render` hook, so the atomic close (write + set
# outcome + close + notify) stays one command and the notification can't be forgotten;
# emit-json falls back to a raw-JSON body if this script fails, so a render bug can
# never drop a human notification.
#
# The first output line is a single-line recap (no early newline) so the inbox's
# 60-char body preview (gc mail inbox) stays tidy; the subject remains the scan key.
set -euo pipefail

VF=""

die() { printf '%s\n' "render-hardbug: $*" >&2; exit 2; }
usage() {
    printf '%s\n' \
        "usage: render-hardbug.sh [<hardbug.json> | -]" \
        "reads hard-bug-reconcile.v1 / hard-bug-final.v1 JSON from the file arg or stdin ('-')"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -)         VF="-"; shift ;;
        --)        shift ;;
        -*)        die "unknown option '$1'" ;;
        *)         if [ -z "$VF" ]; then VF="$1"; shift; else die "unexpected argument '$1'"; fi ;;
    esac
done

if [ -z "$VF" ] || [ "$VF" = "-" ]; then
    JSON=$(cat)
else
    [ -f "$VF" ] || die "bug file not found: $VF"
    JSON=$(cat "$VF")
fi

printf '%s' "$JSON" | jq -e . >/dev/null 2>&1 || die "input is not valid JSON"

# The renderer, as a jq program. Kept in a quoted heredoc; the object carries its own
# subject (the bug bead), so no --arg context is needed.
PROG=$(cat <<'JQ'
def nn: . != null and . != "";
def yn: if . == true then "yes" elif . == false then "no" else "?" end;
def bstr: if . == null then "?" else (.|tostring) end;
def footer:
  (.subject // "") as $s
  | if ($s|nn) then ["", "—", "track: gc dev-pack status \($s)"] else [] end;

if (.aligned != null) then
    # --- hard-bug-reconcile.v1 -------------------------------------------------
    (.subject // "?")             as $subj
  | (.phase // "?")               as $phase
  | (.round | bstr)               as $round
  | (.aligned | bstr)             as $aligned
  | (.stronger_lane // "?")       as $slane
  | (.stronger_rationale // "")   as $srat
  | (.next_action // "?")         as $next
  | (.stuck)                      as $stuck
  | (.failure_class // "none")    as $fclass
  | (.failure_reason // "")       as $freason
  | (.n)                          as $ncount
  | (($ncount == 1))              as $solo
  | (if $aligned == "true" then "passed" else "caveat" end) as $selfv
  | (
      ( if $solo
        then [ ( ["bug \($subj) \($phase) r\($round)",
                 "solo (N=1)", "self-verify=\($selfv)", "next=\($next)"] | join(" · ") ),
               "",
               "## Bug — \($subj)   (\($phase), round \($round))",
               "opinions: 1 (solo)   self-verify: \($selfv)   next: \($next)" ]
        else [ ( ["bug \($subj) \($phase) r\($round)",
                 "aligned=\($aligned)", "stronger=\($slane)", "next=\($next)"] | join(" · ") ),
               "",
               "## Bug — \($subj)   (\($phase), round \($round))",
               "aligned: \($aligned)   stronger lane: \($slane)   next: \($next)"
               + (if ($stuck == true) then "   (stuck)" else "" end) ]
        end )
      + (if $fclass != "none" then ["", "⚠ step \($fclass): \($freason)"] else [] end)
      + (if (.report != null)
         then ( .report as $r
                | ["", "Root cause" + (if ($r.confidence|nn) then " (confidence: \($r.confidence))" else "" end),
                   "  \($r.root_cause // "?")"]
                + (if ($r.mechanism|nn) then ["", "Mechanism", "  \($r.mechanism)"] else [] end)
                + (if ($r.proposed_fix != null)
                   then ["", "Proposed fix"]
                        + (if ($r.proposed_fix.summary|nn) then ["  \($r.proposed_fix.summary)"] else [] end)
                        + (($r.proposed_fix.changes // []) | map("  - \(.file // "?"): \(.what // "?")"))
                   else [] end)
                + (if (($r.key_evidence // []) | length) > 0
                   then ["", "Key evidence"]
                        + ($r.key_evidence | map("  - \(.ref // "?")" + (if (.note|nn) then " — \(.note)" else "" end)))
                   else [] end) )
         else [] end)
      + (if ($solo | not) and ($srat|nn) then ["", "Stronger lane", "  \($slane) — \($srat)"] else [] end)
      + (if $solo then []
         else ["", "Divergences"]
              + (if ((.divergences // []) | length) == 0
                 then ["  (none — the lanes align on this dimension)"]
                 else ( .divergences | to_entries | map(
                          (.key + 1) as $n | .value as $d |
                          [ "  \($n). \($d.topic // "(untitled)")" ]
                          + (if ($d.lane_a_position|nn) then ["     lane A: \($d.lane_a_position)"] else [] end)
                          + (if ($d.lane_b_position|nn) then ["     lane B: \($d.lane_b_position)"] else [] end)
                          + (if ($d.why_it_matters|nn) then ["     why it matters: \($d.why_it_matters)"] else [] end)
                        ) | add )
                 end)
         end)
      + (if ((.unverified_keystones // []) | length) > 0
         then ["", "Unverified keystones"]
              + ( .unverified_keystones | map(
                    "  - \(.fact // "?")  [both-unverified=\(.both_lanes_unverified|yn), cheaply-verifiable=\(.cheaply_verifiable|yn), action=\(.action // "?")]" ) )
         else [] end)
      + ["", "What happens next"]
      + [ "  " + (
            if   $next == "report_only"        then "Stage-1 report only — nothing was changed. Review the root cause above, then re-run with --loop to " + (if $solo then "act on it" else "drive convergence" end) + ", or take it from here."
            elif $next == "escalate"           then "The lanes did not converge (or are stuck) — this arc is held for you (hold=mayor). Review the divergence above and adjust the direction, or fix it directly."
            elif $next == "relay_next_round"   then "Converging automatically — the coordinator is relaying each lane's position into another round. No action needed."
            elif $next == "advance_phase"      then "Root cause agreed — advancing to the fix phase automatically. No action needed."
            elif $next == "choose_implementer" then "Fix agreed — the stronger lane will implement and the other cross-review. No action needed."
            else "next action: \($next)." end ) ]
      + footer
      | join("\n")
    )
elif (.concurred != null) or (.branch != null) or (.status != null) then
    # --- hard-bug-final.v1 ----------------------------------------------------
    (.subject // "?")             as $subj
  | (.status // "?")              as $status
  | (.concurred | yn)             as $concurred
  | (.branch // "")               as $branch
  | (.summary // "")              as $summary
  | (.next_action // "")          as $next
  | (.failure_class // "none")    as $fclass
  | (.failure_reason // "")       as $freason
  | (
      [ ( ["bug \($subj): \($status)"]
          + (if ($branch|nn) then [$branch] else [] end) | join(" · ") ),
        "",
        "## Bug finalize — \($subj)",
        "status: \($status)   concurred: \($concurred)"
        + (if ($branch|nn) then "   branch: \($branch)" else "" end) ]
      + (if $fclass != "none" then ["", "⚠ step \($fclass): \($freason)"] else [] end)
      + (if ($summary|nn) then ["", "Summary", "  \($summary)"] else [] end)
      + ["", "What happens next"]
      + [ "  " + (
            if   $status == "done"      then "Fix implemented and cross-review concurred" + (if ($branch|nn) then " on branch \($branch)" else "" end) + ". Not merged — open/merge a PR to land it."
            elif $status == "escalated" then "Could not finalize automatically — held for you (hold=mayor)." + (if ($branch|nn) then " Review branch \($branch) and the summary above." else " Review the summary above." end)
            elif $status == "reopened"  then "Re-entering the fix phase — the coordinator is running another round. No action needed."
            else (if ($next|nn) then "next action: \($next)." else "See the summary above." end) end ) ]
      + footer
      | join("\n")
    )
else
    # --- unrecognized bug schema: safe generic dump ----------------------
    [ "bug step (\(.subject // "?"))",
      "",
      "## Bug step — \(.subject // "?")",
      "(unrecognized schema — raw fields below)",
      "" ]
    + ( to_entries | map("  \(.key): \(.value | tojson)") )
    | join("\n")
end
JQ
)

printf '%s\n' "$JSON" | jq -r "$PROG"
