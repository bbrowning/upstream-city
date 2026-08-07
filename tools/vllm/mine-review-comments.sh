#!/usr/bin/env bash
# mine-review-comments.sh — DETERMINISTIC seed miner for the review-knowledge flywheel.
#
# Bootstraps (and, for the Phase-4 recurring re-mine, refreshes) the per-domain
# knowledge corpus by pulling maintainer inline review comments from recently-merged
# vLLM PRs that touch our domains, keeping ONLY comments authored by a CODEOWNER for
# the touched path (bots dropped), and emitting them as raw candidates for an LLM
# distillation pass + human curation. NO LLM here — this is the fetch/filter half.
#
#   mine-review-comments.sh [--since 90d] [--out <dir>] [--max-prs N] [--dry-run]
#                           [--repo owner/name] [--codeowners <file>]
#
# Output: <out>/candidates-raw.jsonl — one JSON object per kept comment:
#   {domain, pr, url, author, assoc, path, line, diff_hunk, body}
# (<out> defaults to $GC_PR_KNOWLEDGE/_seed.)
#
# WHY CODEOWNERS, not author_association: vLLM maintainers split across MEMBER /
# COLLABORATOR unreliably, so association alone misclassifies them. We resolve
# "is this author a maintainer for THIS path's domain?" against CODEOWNERS instead.
#
# RATE LIMITS: we discover PRs by path via the commits API with a server-side
# `since` filter (cheap), then spend ~1 paginated call per unique PR. Never a full
# repo scan. --max-prs caps it; a cap that bites is logged (no silent truncation).
#
# Domains (vLLM-specific — this script is why the corpus lives outside the generic
# pack): parsers (vllm/tool_parsers + vllm/reasoning + vllm/parser [Parser Engine]),
# openai_frontend (vllm/entrypoints/openai).
set -euo pipefail

REPO="vllm-project/vllm"
SINCE="90d"
OUTDIR="${GC_PR_KNOWLEDGE:-}"
[ -n "$OUTDIR" ] && OUTDIR="$OUTDIR/_seed"
MAX_PRS=200
DRY_RUN=0
CODEOWNERS_FILE=""

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }
log() { printf 'mine: %s\n' "$*" >&2; }
die() { printf 'mine: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --since)        SINCE="${2:?}"; shift 2 ;;
        --since=*)      SINCE="${1#*=}"; shift ;;
        --out)          OUTDIR="${2:?}"; shift 2 ;;
        --out=*)        OUTDIR="${1#*=}"; shift ;;
        --max-prs)      MAX_PRS="${2:?}"; shift 2 ;;
        --max-prs=*)    MAX_PRS="${1#*=}"; shift ;;
        --repo)         REPO="${2:?}"; shift 2 ;;
        --repo=*)       REPO="${1#*=}"; shift ;;
        --codeowners)   CODEOWNERS_FILE="${2:?}"; shift 2 ;;
        --codeowners=*) CODEOWNERS_FILE="${1#*=}"; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "unknown argument '$1' (see --help)" ;;
    esac
done

command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"

# Resolve CODEOWNERS: explicit flag wins; else derive the vllm rig root via gc (the
# portable resolver materialize/fetch-origin use — NOT `git rev-parse --show-toplevel`,
# which resolves to whatever repo you're standing in, not the rig); else the
# conventional path.
if [ -z "$CODEOWNERS_FILE" ]; then
    GC="${GC_BIN:-gc}"; CITY="${GC_CITY_PATH:-${GC_CITY:-}}"
    if [ -n "$CITY" ]; then
        rig_root=$("$GC" --city "$CITY" rig list --json 2>/dev/null | jq -r '.rigs[]? | select(.name=="vllm") | .path' 2>/dev/null || true)
    else
        rig_root=$("$GC" rig list --json 2>/dev/null | jq -r '.rigs[]? | select(.name=="vllm") | .path' 2>/dev/null || true)
    fi
    for c in "${rig_root:+$rig_root/.github/CODEOWNERS}" "/pvc/workspace/rigs/vllm/.github/CODEOWNERS"; do
        [ -n "$c" ] && [ -f "$c" ] && { CODEOWNERS_FILE="$c"; break; }
    done
fi
[ -n "$CODEOWNERS_FILE" ] && [ -f "$CODEOWNERS_FILE" ] || die "CODEOWNERS not found (pass --codeowners <file>)"

[ -n "$OUTDIR" ] || die "output dir unknown: export \$GC_PR_KNOWLEDGE or pass --out <dir>"

# --since 90d -> ISO; a bare ISO date is passed through.
case "$SINCE" in
    *d) SINCE_ISO=$(date -u -d "${SINCE%d} days ago" +%Y-%m-%dT%H:%M:%SZ) ;;
    *)  SINCE_ISO="$SINCE" ;;
esac
log "repo=$REPO since=$SINCE_ISO codeowners=$CODEOWNERS_FILE out=$OUTDIR max-prs=$MAX_PRS"

# --- CODEOWNERS -> per-domain owner sets (union owners of lines under each prefix) --
owners_for_prefixes() {  # <prefix>...  -> unique @handles
    awk -v prefixes="$*" '
        BEGIN { n = split(prefixes, P, " ") }
        /^#/ || NF < 2 { next }
        { pat = $1; sub(/^\//, "", pat)
          for (i = 1; i <= n; i++) if (index(pat, P[i]) == 1) {
              for (j = 2; j <= NF; j++) if ($j ~ /^@/) print $j
              break
          } }' "$CODEOWNERS_FILE" | sort -u
}
to_json_array() { jq -Rn '[inputs]'; }

OWNERS_JSON=$(jq -n \
    --argjson parsers         "$(owners_for_prefixes vllm/tool_parsers tests/tool_parsers tests/tool_use vllm/reasoning tests/reasoning vllm/parser tests/parser | to_json_array)" \
    --argjson openai_frontend "$(owners_for_prefixes vllm/entrypoints/openai tests/entrypoints | to_json_array)" \
    '{parsers:$parsers, openai_frontend:$openai_frontend}')
log "owner sets: $(printf '%s' "$OWNERS_JSON" | jq -c 'map_values(length)')"

# --- discover domain PRs by path (commits API, server-side `since`) ----------
discover() {  # <source-path> -> PR numbers (trailing "(#N)" in squash subjects)
    gh api -X GET "repos/$REPO/commits" \
        -f path="$1" -f since="$SINCE_ISO" -f per_page=100 --paginate \
        --jq '.[].commit.message | split("\n")[0]' 2>/dev/null \
    | sed -nE 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p'
}

log "discovering PRs by path…"
PRS=$( { discover vllm/tool_parsers; discover vllm/reasoning; discover vllm/parser; discover vllm/entrypoints/openai; } \
         | sort -un )
NPR=$(printf '%s\n' "$PRS" | grep -c . || true)
log "discovered $NPR unique domain PRs since $SINCE_ISO"

if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run: not fetching comments. PR numbers:"
    printf '%s\n' "$PRS" | paste -sd' ' -
    exit 0
fi

if [ "$MAX_PRS" -gt 0 ] && [ "$NPR" -gt "$MAX_PRS" ]; then
    log "WARNING: capping at --max-prs=$MAX_PRS of $NPR discovered PRs (raise --max-prs to cover all)"
    PRS=$(printf '%s\n' "$PRS" | head -n "$MAX_PRS")
fi

mkdir -p "$OUTDIR"
OUT="$OUTDIR/candidates-raw.jsonl"
: > "$OUT"

# --- per PR: fetch inline comments once, classify by path, keep CODEOWNER-authored --
done=0
for pr in $PRS; do
    done=$((done + 1))
    gh api "repos/$REPO/pulls/$pr/comments?per_page=100" --paginate 2>/dev/null \
      | jq -c --arg pr "$pr" --argjson owners "$OWNERS_JSON" '
          def domain(p):
              if   (p|test("/tool_parsers/"))       then "parsers"
              elif (p|test("/reasoning/"))          then "parsers"
              elif (p|test("/tool_use/"))           then "parsers"
              elif (p|test("/entrypoints/openai/")) then "openai_frontend"
              elif (p|test("/parser/"))             then "parsers"
              else null end;
          .[]
          | . as $c
          | (domain(.path // "")) as $d
          | select($d != null)
          | select((.user.login // "") | endswith("[bot]") | not)
          | select(("@" + (.user.login // "")) as $u | ($owners[$d] // []) | any(. == $u))
          | select(((.body // "") | gsub("\\s";"") | length) > 0)
          | {domain:$d, pr:($pr|tonumber), url:(.html_url // ""),
             author:(.user.login // ""), assoc:(.author_association // ""),
             path:(.path // ""), line:(.line // null),
             diff_hunk:(.diff_hunk // ""), body:(.body // "")}
        ' >> "$OUT" 2>/dev/null || log "warn: could not fetch/parse comments for PR #$pr"
    if [ $((done % 25)) -eq 0 ]; then log "…processed $done/$NPR PRs"; fi
done

kept=$(grep -c . "$OUT" 2>/dev/null || true)
log "wrote $kept kept comments to $OUT"
log "by domain: $(jq -s -c 'group_by(.domain) | map({(.[0].domain): length}) | add // {}' "$OUT" 2>/dev/null || echo '{}')"
log "by author: $(jq -s -c 'group_by(.author) | map({(.[0].author): length}) | add // {}' "$OUT" 2>/dev/null || echo '{}')"
log "next: distill per domain -> <domain>.candidates.md, then: gc pr-review-pack learn --from-candidates <file>"
