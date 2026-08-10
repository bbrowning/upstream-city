#!/usr/bin/env bash
# posture-latitude.sh — PURE fixed posture->latitude table. No diff, no network,
# no LLM, no state. The reviewer evals this to gate ITSELF:
#
#   eval "$(posture-latitude.sh "$effective_posture")"   # sets FETCH EXEC GATE
#
# Keeping it a trivially-auditable pure function is the point: a prompt-injected
# reviewer cannot widen its own latitude by talking to this script — the mapping
# is fixed here in the pack, and the *posture* it is handed was already floored by
# the deterministic pr-prescan.sh ceiling.
#
#   FETCH : none      -> no external network at all
#           metadata  -> read-only metadata probes only (no artifact bodies)
#           allowlist -> ONLY HF config JSON + safetensors headers
#   EXEC  : deny      -> never run any changed/untrusted code
#           allow     -> may run in-scope unit tests on changed code
#   GATE  : none      -> no human gate; run the in-scope check iff EXEC=allow
#                        (trusted), else just review the text (restricted)
#           human     -> surface a scoped approval request; do NOT run it yourself
#                        (a human runs it via the pr-review-dynamic lane)
#           blocked   -> do not review; route to a human
#           suggest   -> RETIRED in Phase 2 (was the Phase-1 trusted preview token)
#
# PHASE 2 (LIVE): only the `trusted` row grants EXEC=allow — the reviewer may
# auto-run ONE in-scope check on changed code, unattended, via run-scoped-check.sh
# (which re-derives the deterministic ceiling and refuses if it dropped). Every
# other posture stays EXEC=deny: an agent NEVER runs limited/restricted/block code
# on its own. `limited` execution happens ONLY out-of-band, when a human slings the
# `pr-review-dynamic` approval lane — that lane adds the human's EXEC token on top
# of this same deterministic floor; it does NOT go through this table (which
# correctly still says `deny` for what an agent may do unattended).
set -euo pipefail

POSTURE="${1:?usage: posture-latitude.sh <trusted|limited|restricted|block>}"

case "$POSTURE" in
    trusted)    echo 'FETCH=allowlist EXEC=allow GATE=none' ;;    # Phase 2: reviewer auto-runs one in-scope check
    limited)    echo 'FETCH=metadata EXEC=deny GATE=human' ;;
    restricted) echo 'FETCH=none EXEC=deny GATE=none' ;;
    block)      echo 'FETCH=none EXEC=deny GATE=blocked' ;;
    *) echo "posture-latitude: unknown posture '$POSTURE'" >&2; exit 2 ;;
esac
