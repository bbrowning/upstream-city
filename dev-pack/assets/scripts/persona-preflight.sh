#!/usr/bin/env bash
# Make persona availability an explicit, machine-readable review preflight.
set -euo pipefail

CORPUS="${GC_PERSONAS:-}"
REQUIRED="${GC_PERSONAS_REQUIRED:-false}"
case "$REQUIRED" in true|false) ;; *) printf 'persona-preflight: GC_PERSONAS_REQUIRED must be true or false\n' >&2; exit 2 ;; esac

if [ -n "$CORPUS" ] && [ -d "$CORPUS" ] && [ -r "$CORPUS/base.md" ]; then
    count=$(find "$CORPUS" -maxdepth 1 -type f -name '*.md' | wc -l)
    jq -cn --arg corpus "$CORPUS" --argjson required "$REQUIRED" --argjson files "$count" \
        '{schema:"persona-preflight.v1",available:true,required:$required,corpus:$corpus,files:$files,fallback:null}'
    exit 0
fi

result=$(jq -cn --arg corpus "$CORPUS" --argjson required "$REQUIRED" \
    '{schema:"persona-preflight.v1",available:false,required:$required,
      corpus:(if $corpus=="" then null else $corpus end),files:0,fallback:"first-principles",
      error:"persona-corpus-unavailable"}')
if [ "$REQUIRED" = "true" ]; then
    printf '%s\n' "$result" >&2
    printf 'persona-preflight: persona-corpus-unavailable: set GC_PERSONAS to a readable directory containing base.md\n' >&2
    exit 2
fi
printf '%s\n' "$result"
