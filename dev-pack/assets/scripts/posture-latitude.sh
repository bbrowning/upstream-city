#!/usr/bin/env bash
# posture-latitude.sh — PURE fixed posture->latitude table. No diff, no network,
# no LLM, no state. The reviewer evals this to gate ITSELF:
#
#   eval "$(posture-latitude.sh "$effective_posture" [external|internal-producer])"
#                                                        # sets FETCH EXEC GATE
#
# Keeping it a trivially-auditable pure function is the point: a prompt-injected
# reviewer cannot widen its own latitude by talking to this script — the mapping
# is fixed here in the pack, and the *posture* it is handed was already floored by
# the deterministic pr-prescan.sh ceiling.
#
#   FETCH : none      -> no external network at all
#           metadata  -> read-only metadata probes only (no artifact bodies)
#           allowlist -> read-only fetches permitted by the city egress sandbox
#   EXEC  : deny      -> never run any changed/untrusted code
#           allow     -> may run in-scope unit tests on changed code
#   GATE  : none      -> no human gate; run the in-scope check iff EXEC=allow
#                        (trusted), else just review the text (restricted)
#           human     -> surface a scoped approval request; do NOT run it yourself
#                        (a human runs it via the pr-review-dynamic lane)
#           blocked   -> do not review; route to a human
#           suggest   -> RETIRED in Phase 2 (was the Phase-1 trusted preview token)
#
# PHASE 2 (LIVE): `trusted` input grants the same allowlisted, read-only fetch
# latitude whether its identity authority is external or an internal producer; the
# city's egress sandbox remains the hard network boundary. A provenance-validated
# internal producer artifact also grants bounded execution when content scanning caps
# it at `limited`, but does not gain network latitude at that posture. Producer
# authority never overrides `restricted` or `block` content signals. `limited`
# external execution remains human-only through pr-review-dynamic.
set -euo pipefail

POSTURE="${1:?usage: posture-latitude.sh <trusted|limited|restricted|block> [external|internal-producer]}"
AUTHORITY="${2:-external}"
case "$AUTHORITY" in external|internal-producer) ;; *) echo "posture-latitude: unknown authority '$AUTHORITY'" >&2; exit 2 ;; esac

case "$POSTURE:$AUTHORITY" in
    trusted:*)                  echo 'FETCH=allowlist EXEC=allow GATE=none' ;;
    limited:internal-producer)  echo 'FETCH=none EXEC=allow GATE=none' ;;
    limited:external)           echo 'FETCH=metadata EXEC=deny GATE=human' ;;
    restricted:*) echo 'FETCH=none EXEC=deny GATE=none' ;;
    block:*)      echo 'FETCH=none EXEC=deny GATE=blocked' ;;
    *) echo "posture-latitude: unknown posture '$POSTURE'" >&2; exit 2 ;;
esac
