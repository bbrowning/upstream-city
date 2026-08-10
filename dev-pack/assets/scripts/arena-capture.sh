#!/usr/bin/env bash
# arena-capture — refresh the model-arena log so new N>=2 decisions (and their
# per-participant Claude Code transcript token counts) are captured automatically.
#
# Runs as an exec order (no LLM, no agent, no wisp) — the durable, controller-hosted
# cousin of a cron job. arena_refresh.py is idempotent and cost-preserving (merges by
# decision_id, preserves prior token counts), so re-running every interval is free and
# safe; it only adds newly-closed decisions. Token counts are captured well within
# Claude Code's transcript retention (cleanupPeriodDays, ~30d).
#
# Env (provided to order exec by gascity): GC_CITY (city root). Override the refresher
# path with GC_ARENA_REFRESH so this pack stays project-agnostic (cf. fetch-origin's
# GC_FETCH_RIGS). A missing refresher is a clean no-op (the rig may not ship arena).
set -euo pipefail
REPO="${GC_CITY:-/pvc/workspace}"
REFRESH="${GC_ARENA_REFRESH:-$REPO/tools/vllm/arena/arena_refresh.py}"
[ -f "$REFRESH" ] || exit 0
exec python3 "$REFRESH" --quiet
