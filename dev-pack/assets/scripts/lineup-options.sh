#!/usr/bin/env bash
# lineup-options.sh — print the VALID option values for a provider so `gc dev-pack
# review --lineup` can fail fast on an unresolvable model/effort BEFORE it slings.
#
# WHY this exists: gascity resolves a model by exact-match against a curated choice
# enum; on the launch path an UNKNOWN value is silently dropped (no --model emitted)
# and the provider falls back to its own default. There is no command-time error and
# no pure-CLI JSON of the choice list — so the pack validates up front against the
# running binary's real (merged) schema.
#
#   lineup-options.sh <provider>
#     -> two lines on stdout:
#          model  <space-separated valid values>
#          effort <space-separated valid values>
#     -> exit 3 if the provider can't be resolved at all.
#
# Source of truth, in order:
#   1. the RUNNING binary's MERGED schema (builtin + city.toml `by_key` choices) via
#      GET {api}/v0/city/{city}/providers/public  — drift-free, includes custom models.
#   2. the checked-in allowlist ../valid-options.txt when the API is unreachable.
#
# Env: GC_DASHBOARD_BASE (default http://127.0.0.1:8372/city/workspace/runs) supplies
# the API host + city name; override directly with GC_API_BASE / GC_CITY_NAME.
set -euo pipefail

PROV="${1:-}"
[ -n "$PROV" ] || { printf '%s\n' "lineup-options: usage: lineup-options.sh <provider>" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWLIST="${SCRIPT_DIR}/../valid-options.txt"

DASH="${GC_DASHBOARD_BASE:-http://127.0.0.1:8372/city/workspace/runs}"
API_BASE="${GC_API_BASE:-}"
[ -n "$API_BASE" ] || API_BASE="$(printf '%s' "$DASH" | sed -E 's#^(https?://[^/]+).*#\1#')"
CITY="${GC_CITY_NAME:-}"
if [ -z "$CITY" ]; then
    CITY="$(printf '%s' "$DASH" | sed -E 's#^https?://[^/]+/city/([^/]+).*#\1#')"
    [ -n "$CITY" ] && [ "$CITY" != "$DASH" ] || CITY="workspace"
fi

# --- 1. API (merged schema; drift-free) — fetched at most once ----------------
JSON="" ; JSON_FETCHED=""
fetch_json() {
    [ -n "$JSON_FETCHED" ] && return 0
    JSON_FETCHED=1
    JSON="$(curl -fsS --max-time 2 "${API_BASE}/v0/city/${CITY}/providers/public" 2>/dev/null || true)"
}
api_values() {  # $1=key -> space-separated values (empty on any failure)
    local key="$1"
    fetch_json
    [ -n "$JSON" ] || return 0
    printf '%s' "$JSON" | jq -r --arg p "$PROV" --arg k "$key" '
        (.items // .)[]? | select(.name == $p)
        | .options_schema[]? | select(.key == $k) | .choices[]?.value // empty
    ' 2>/dev/null | grep -v '^$' | paste -sd' ' - || true
}

# --- 2. allowlist fallback (lines: "<provider> <key> v1 v2 ...") --------------
file_values() {  # $1=key
    local key="$1"
    [ -f "$ALLOWLIST" ] || return 0
    awk -v p="$PROV" -v k="$key" '($1==p && $2==k){ $1=""; $2=""; sub(/^ +/,""); print; exit }' "$ALLOWLIST"
}

MODELS="$(api_values model)"  ; [ -n "$MODELS" ]  || MODELS="$(file_values model)"
EFFORTS="$(api_values effort)"; [ -n "$EFFORTS" ] || EFFORTS="$(file_values effort)"

if [ -z "$MODELS" ] && [ -z "$EFFORTS" ]; then
    printf '%s\n' "lineup-options: provider '$PROV' not resolvable (API unreachable at ${API_BASE} and not in ${ALLOWLIST})" >&2
    exit 3
fi

printf 'model %s\n'  "$MODELS"
printf 'effort %s\n' "$EFFORTS"
