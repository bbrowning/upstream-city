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
#   GATE  : none      -> proceed, no human needed
#           suggest   -> proceed (no approval needed) but surface the check you
#                        WOULD run as a preview dynamic_request; do NOT run it
#           human     -> surface a scoped approval request; do NOT run it yourself
#           blocked   -> do not review; route to a human
#
# PHASE 1: EXEC is 'deny' for EVERY posture (the reviewer is fully read-only).
# Trusted uses GATE=suggest so it still surfaces the (safe, in-scope) command
# Phase 2 will auto-run, as an optional manual run for the human.
# PHASE 2 flips ONLY the trusted row to EXEC=allow GATE=none (see marked line):
# trusted then auto-runs instead of suggesting. Nothing else changes.
set -euo pipefail

POSTURE="${1:?usage: posture-latitude.sh <trusted|limited|restricted|block>}"

case "$POSTURE" in
    trusted)    echo 'FETCH=allowlist EXEC=deny GATE=suggest' ;;   # Phase 2: EXEC=allow GATE=none
    limited)    echo 'FETCH=metadata EXEC=deny GATE=human' ;;
    restricted) echo 'FETCH=none EXEC=deny GATE=none' ;;
    block)      echo 'FETCH=none EXEC=deny GATE=blocked' ;;
    *) echo "posture-latitude: unknown posture '$POSTURE'" >&2; exit 2 ;;
esac
